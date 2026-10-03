import AVFoundation
import AppKit
import LightrayCore

/// Shows the decoded video, aspect-fit, and turns keyboard and mouse events over it into input
/// messages. The host draws the cursor into the video, so the local one is hidden over it.
final class VideoView: NSView {
    let renderer = VideoRenderer()
    /// The video's size in pixels, once a keyframe has decoded. Set on the main thread.
    var videoSize: CGSize?
    /// Called on the main thread for every input message.
    var onInput: ((InputMessage) -> Void)?
    /// The host's display this view shows, named in every pointer position; 0 until known.
    var displayID: UInt32 = 0

    private var heldKeys = Set<UInt16>()
    private var heldButtons = Set<InputMessage.PointerButton>()
    private var scrollRemainder = CGPoint.zero
    private var keyMonitor: Any?
    private let blankCursor = NSCursor(image: NSImage(size: NSSize(width: 1, height: 1)), hotSpot: .zero)

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer = CALayer()
        wantsLayer = true
        layer!.backgroundColor = NSColor.black.cgColor
        renderer.displayLayer.frame = bounds
        renderer.displayLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer!.addSublayer(renderer.displayLayer)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        // Keys go through a local monitor rather than keyDown: AppKit never delivers keyUp for a
        // key pressed with Command, and Command shortcuts belong to the host, not this app.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self, let window = self.window, event.window === window, window.isKeyWindow else { return event }
            return self.handleKey(event) ? nil : event
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(releaseEverything), name: NSWindow.didResignKeyNotification, object: window)
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: blankCursor) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    // MARK: Keyboard

    /// Returns true if the event was taken.
    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.type {
        case .keyDown:
            // ⌃⌥⌘Q quits the client; every other combination goes to the host.
            if event.keyCode == 0x0C, flags.contains([.control, .option, .command]) {
                NSApp.terminate(nil)
                return true
            }
            guard let usage = KeyMap.usage(forKeyCode: event.keyCode) else { return true }
            heldKeys.insert(usage)
            onInput?(.key(usage: usage, down: true, isRepeat: event.isARepeat))
        case .keyUp:
            guard let usage = KeyMap.usage(forKeyCode: event.keyCode), heldKeys.remove(usage) != nil else { return true }
            onInput?(.key(usage: usage, down: false, isRepeat: false))
        case .flagsChanged:
            guard let usage = KeyMap.usage(forKeyCode: event.keyCode) else { return true }
            if usage == KeyMap.capsLockUsage {
                // One event per toggle; the host keeps the lock state.
                onInput?(.key(usage: usage, down: true, isRepeat: false))
                onInput?(.key(usage: usage, down: false, isRepeat: false))
            } else if let modifier = KeyMap.modifier(forUsage: usage) {
                let down = event.modifierFlags.rawValue & UInt(KeyMap.deviceMask(modifier)) != 0
                if down {
                    heldKeys.insert(usage)
                } else if heldKeys.remove(usage) == nil {
                    return true
                }
                onInput?(.key(usage: usage, down: down, isRepeat: false))
            }
        default:
            return false
        }
        return true
    }

    /// When the window stops being key, nothing may stay pressed on the host.
    @objc func releaseEverything() {
        for usage in heldKeys { onInput?(.key(usage: usage, down: false, isRepeat: false)) }
        for button in heldButtons { onInput?(.button(button, down: false)) }
        heldKeys.removeAll()
        heldButtons.removeAll()
    }

    // MARK: Pointer

    private func pointer(_ event: NSEvent) {
        guard let size = videoSize, size.width > 0, size.height > 0 else { return }
        let p = convert(event.locationInWindow, from: nil)
        let rect = AVMakeRect(aspectRatio: size, insideRect: bounds)
        let x = min(max((p.x - rect.minX) / rect.width, 0), 1)
        let y = min(max((p.y - rect.minY) / rect.height, 0), 1)
        onInput?(.pointer(x: UInt16((x * 65535).rounded()), y: UInt16((y * 65535).rounded()), display: displayID))
    }

    private func button(_ event: NSEvent, down: Bool) {
        let button: InputMessage.PointerButton
        switch event.buttonNumber {
        case 0: button = .left
        case 1: button = .right
        case 2: button = .middle
        case 3: button = .back
        case 4: button = .forward
        default: return
        }
        pointer(event)
        if down {
            window?.makeFirstResponder(self)
            heldButtons.insert(button)
        } else if heldButtons.remove(button) == nil {
            return
        }
        onInput?(.button(button, down: down))
    }

    override func mouseMoved(with event: NSEvent) { pointer(event) }
    override func mouseDragged(with event: NSEvent) { pointer(event) }
    override func rightMouseDragged(with event: NSEvent) { pointer(event) }
    override func otherMouseDragged(with event: NSEvent) { pointer(event) }
    override func mouseDown(with event: NSEvent) { button(event, down: true) }
    override func mouseUp(with event: NSEvent) { button(event, down: false) }
    override func rightMouseDown(with event: NSEvent) { button(event, down: true) }
    override func rightMouseUp(with event: NSEvent) { button(event, down: false) }
    override func otherMouseDown(with event: NSEvent) { button(event, down: true) }
    override func otherMouseUp(with event: NSEvent) { button(event, down: false) }

    override func scrollWheel(with event: NSEvent) {
        let units: InputMessage.ScrollUnits
        var delta: CGPoint
        if event.hasPreciseScrollingDeltas {
            // Trackpads and Magic Mice: pixels, fractions carried to the next event.
            units = .pixels
            delta = CGPoint(x: event.scrollingDeltaX, y: event.scrollingDeltaY)
        } else {
            // Wheels report lines; send 1/120 of a notch per unit.
            units = .wheelNotch120
            delta = CGPoint(x: event.scrollingDeltaX * 120, y: event.scrollingDeltaY * 120)
        }
        delta.x += scrollRemainder.x
        delta.y += scrollRemainder.y
        let dx = delta.x.rounded(.towardZero)
        let dy = delta.y.rounded(.towardZero)
        scrollRemainder = CGPoint(x: delta.x - dx, y: delta.y - dy)
        guard dx != 0 || dy != 0 else { return }
        onInput?(.scroll(dx: Int16(clamping: Int(dx)), dy: Int16(clamping: Int(dy)), units: units))
    }
}
