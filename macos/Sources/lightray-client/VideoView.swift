import AVFoundation
import AppKit
import LightrayCore
import LightrayMac

/// Shows the decoded video, aspect-fit, and turns keyboard and mouse events over it into input
/// messages. The host draws the cursor into the video, so the local one is hidden over it.
final class VideoView: NSView {
    let displayLayer = AVSampleBufferDisplayLayer()
    /// The video's size in pixels, once a keyframe has decoded. Set on the main thread.
    var videoSize: CGSize? { didSet { updateOverlay() } }
    /// Called on the main thread for every input message.
    var onInput: ((InputMessage) -> Void)?
    /// The host's display this view shows, named in every pointer position; 0 until known.
    var displayID: UInt32 = 0
    var localCursor = false {
        didSet { window?.invalidateCursorRects(for: self) }
    }

    private var keyboard = RemoteKeyboard()
    private let sessionButton = NSButton(title: "Lightray · Waiting", target: nil, action: nil)
    private let sessionPopover = NSPopover()
    var onPreferencesChange: ((SessionPreferences) -> Void)?
    var onResetPreferences: (() -> Void)?
    var onDisconnect: (() -> Void)?
    var streamState: StreamActivity.State = .waiting {
        didSet {
            if streamState != .live { releaseEverything() }
            window?.invalidateCursorRects(for: self)
            updateOverlay()
        }
    }
    var streamStateText: String {
        switch streamState {
        case .waiting: "Waiting for video"
        case .live: "Live video"
        case .interrupted: "Video interrupted · remote input paused"
        }
    }
    var canSendInput: Bool { inputEnabled && streamState == .live }
    private let statisticsOverlay = StatisticsOverlay(frame: .zero)
    var statisticsVisible = true {
        didSet {
            statisticsOverlay.isHidden = !statisticsVisible
            if statisticsVisible { updateOverlay() }
        }
    }
    var statisticsText = "Waiting for stream…" { didSet { updateOverlay() } }
    var onHotkey: ((ClientHotkey) -> Void)?
    private(set) var inputEnabled = true
    private var suppressLocalChord = false
    private var suppressedKeyUps = Set<UInt16>()
    var keyboardMapping: RemoteKeyboard.Mapping {
        get { keyboard.mapping }
        set { emit(keyboard.setMapping(newValue)); updateOverlay() }
    }
    private var heldButtons = Set<InputMessage.PointerButton>()
    private var scrollRemainder = CGPoint.zero
    private var keyMonitor: Any?
    private let blankCursor = NSCursor(image: NSImage(size: NSSize(width: 1, height: 1)), hotSpot: .zero)

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer = CALayer()
        wantsLayer = true
        layer!.backgroundColor = NSColor.black.cgColor
        displayLayer.videoGravity = .resizeAspect
        displayLayer.frame = bounds
        displayLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer!.addSublayer(displayLayer)
        sessionButton.target = self
        sessionButton.action = #selector(toggleSessionMenu)
        sessionButton.bezelStyle = .rounded
        sessionButton.contentTintColor = NSColor(calibratedRed: 0.15, green: 0.76, blue: 0.86, alpha: 1)
        sessionButton.toolTip = "Session controls (⌃⌥⌘S)"
        sessionButton.setAccessibilityLabel("Lightray session menu")
        sessionButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(sessionButton)
        sessionPopover.behavior = .transient
        statisticsOverlay.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statisticsOverlay)
        NSLayoutConstraint.activate([
            statisticsOverlay.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            sessionButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            sessionButton.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            statisticsOverlay.topAnchor.constraint(equalTo: sessionButton.bottomAnchor, constant: 8),
            statisticsOverlay.widthAnchor.constraint(lessThanOrEqualToConstant: 380),
            statisticsOverlay.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
        ])
        updateOverlay()
        NotificationCenter.default.addObserver(self, selector: #selector(releaseEverything), name: NSApplication.didResignActiveNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        guard let window else { releaseEverything(); return }
        // Keys go through a local monitor rather than keyDown: AppKit never delivers keyUp for a
        // key pressed with Command, and Command shortcuts belong to the host, not this app.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self, let window = self.window, event.window === window, window.isKeyWindow else { return event }
            return self.handleKey(event) ? nil : event
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(releaseEverything), name: NSWindow.didResignKeyNotification, object: window)
    }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        NotificationCenter.default.removeObserver(self)
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: localCursor || !canSendInput ? .arrow : blankCursor) }

    private func updateOverlay() {
        sessionButton.title = "Lightray · \(streamState == .live ? (inputEnabled ? "Live" : "Input released") : (streamState == .waiting ? "Waiting" : "Video interrupted"))"
        (sessionPopover.contentViewController as? SessionControls)?.refresh()
        guard statisticsVisible else { return }
        let resolution = videoSize.map { "\(Int($0.width)) × \(Int($0.height))" } ?? "Waiting for video"
        let mapping = keyboard.mapping == .commandControl ? "Command ↔ Control" : "Physical keys"
        let input = inputEnabled ? mapping : "Input released · click video to resume"
        statisticsOverlay.update("\(resolution)\n\(streamStateText)\n\(statisticsText)\n\(input)\n⌃⌥⌘S menu · ⌃⌥⌘Esc release input")
    }

    func applyPreferences(_ preferences: SessionPreferences) {
        if keyboardMapping != preferences.keyboardMapping {
            releaseEverything()
            keyboardMapping = preferences.keyboardMapping
        }
        localCursor = preferences.localCursor
        statisticsVisible = preferences.showStatistics
    }

    @objc func toggleSessionMenu() {
        if sessionPopover.isShown { closeSessionMenu(); return }
        setInputEnabled(false)
        sessionPopover.contentViewController = SessionControls(video: self)
        sessionPopover.contentSize = NSSize(width: 420, height: 600)
        // A wide anchor keeps the panel inside the stream window near its left edge.
        let anchor = NSRect(x: 0, y: sessionButton.frame.minY, width: min(444, bounds.width), height: sessionButton.frame.height)
        sessionPopover.show(relativeTo: anchor, of: self, preferredEdge: .maxY)
    }

    func closeSessionMenu() {
        sessionPopover.close()
        window?.makeFirstResponder(self)
    }

    func setInputEnabled(_ enabled: Bool) {
        releaseEverything()
        inputEnabled = enabled
        window?.invalidateCursorRects(for: self)
        updateOverlay()
    }

    func sendShortcut(_ shortcut: RemoteKeyboard.Shortcut) {
        guard canSendInput else { return }
        releaseEverything()
        emit(keyboard.shortcut(shortcut))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    // MARK: Video

    /// Shows a decoded picture at once. Safe from any one serial queue.
    func enqueue(_ pixels: CVPixelBuffer) {
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixels, formatDescriptionOut: &format)
        guard let format else { return }
        var timing = CMSampleTimingInfo(
            duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil, imageBuffer: pixels, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample)
        guard let sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
            CFArrayGetCount(attachments) > 0
        {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        let renderer = displayLayer.sampleBufferRenderer
        if renderer.status == .failed { renderer.flush() }
        renderer.enqueue(sample)
    }

    // MARK: Keyboard

    private func emit(_ messages: [InputMessage]) { for message in messages { onInput?(message) } }

    /// Returns true if the event was taken.
    private func handleKey(_ event: NSEvent) -> Bool {
        if event.type == .keyUp, suppressedKeyUps.remove(event.keyCode) != nil { return true }
        if event.type == .keyDown, let action = ClientHotkey.match(keyCode: event.keyCode, flags: UInt64(event.modifierFlags.rawValue)) {
            if !event.isARepeat {
                releaseEverything()
                onHotkey?(action)
                suppressLocalChord = true
                suppressedKeyUps.insert(event.keyCode)
            }
            return true
        }
        if suppressLocalChord {
            let flags = event.modifierFlags.intersection([.control, .option, .command, .shift])
            if flags.isEmpty { suppressLocalChord = false }
            return true
        }
        guard canSendInput, window?.firstResponder === self else { return false }
        switch event.type {
        case .keyDown:
            emit(keyboard.synchronizeModifiers(flags: UInt64(event.modifierFlags.rawValue)))
            guard let usage = KeyMap.usage(forKeyCode: event.keyCode) else { return true }
            emit(keyboard.key(usage, down: true, isRepeat: event.isARepeat))
        case .keyUp:
            emit(keyboard.synchronizeModifiers(flags: UInt64(event.modifierFlags.rawValue)))
            guard let usage = KeyMap.usage(forKeyCode: event.keyCode) else { return true }
            emit(keyboard.key(usage, down: false))
        case .flagsChanged:
            guard let usage = KeyMap.usage(forKeyCode: event.keyCode) else { return true }
            if usage == KeyMap.capsLockUsage {
                // One event per toggle; the host keeps the lock state.
                emit(keyboard.key(usage, down: true))
                emit(keyboard.key(usage, down: false))
            } else {
                emit(keyboard.synchronizeModifiers(flags: UInt64(event.modifierFlags.rawValue)))
            }
        default:
            return false
        }
        return true
    }

    /// When the window stops being key, nothing may stay pressed on the host.
    @objc func releaseEverything() {
        emit(keyboard.releaseAll())
        for button in heldButtons { onInput?(.button(button, down: false)) }
        heldButtons.removeAll()
        scrollRemainder = .zero
        suppressLocalChord = false
        suppressedKeyUps.removeAll()
    }

    // MARK: Pointer

    private func pointer(_ event: NSEvent) {
        guard canSendInput else { return }
        guard let size = videoSize, size.width > 0, size.height > 0 else { return }
        let p = convert(event.locationInWindow, from: nil)
        let rect = AVMakeRect(aspectRatio: size, insideRect: bounds)
        let x = min(max((p.x - rect.minX) / rect.width, 0), 1)
        let y = min(max((p.y - rect.minY) / rect.height, 0), 1)
        onInput?(.pointer(x: UInt16((x * 65535).rounded()), y: UInt16((y * 65535).rounded()), display: displayID))
    }

    private func button(_ event: NSEvent, down: Bool) {
        guard canSendInput else {
            if !inputEnabled && streamState == .live && down && event.buttonNumber == 0 { setInputEnabled(true) }
            return
        }
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
        guard canSendInput else { return }
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
