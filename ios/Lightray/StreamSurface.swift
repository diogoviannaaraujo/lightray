import AVFoundation
import LightrayCore
import SwiftUI
import UIKit

/// The shared low-latency renderer, with iPad touch and physical input translated to host input.
struct StreamSurface: UIViewRepresentable {
    let renderer: VideoRenderer
    var videoSize: CGSize
    var displayID: UInt32 = 0
    var inputEnabled = true
    var inputResetGeneration: UInt64 = 0
    var onInput: (InputMessage) -> Void
    var onFocusLost: () -> Void = {}

    func makeUIView(context: Context) -> StreamSurfaceView {
        let view = StreamSurfaceView(frame: .zero)
        updateUIView(view, context: context)
        return view
    }

    func updateUIView(_ view: StreamSurfaceView, context: Context) {
        view.configure(renderer: renderer, videoSize: videoSize, displayID: displayID,
                       inputEnabled: inputEnabled, inputResetGeneration: inputResetGeneration,
                       onInput: onInput, onFocusLost: onFocusLost)
    }

    static func dismantleUIView(_ view: StreamSurfaceView, coordinator: ()) {
        view.detach()
    }
}

@MainActor
final class StreamSurfaceView: UIView, UIGestureRecognizerDelegate, UIPointerInteractionDelegate {
    private var renderer: VideoRenderer?
    private var videoSize = CGSize.zero
    private var displayID: UInt32 = 0
    private var inputEnabled = false
    private var inputResetGeneration: UInt64 = 0
    private var onInput: ((InputMessage) -> Void)?
    private var onFocusLost: (() -> Void)?
    private var keyboard = RemoteKeyboard()
    private var heldButtons = Set<InputMessage.PointerButton>()
    private var pointerSequenceActive = false
    private var scrollRemainder = CGPoint.zero
    private var pointerInteraction: UIPointerInteraction!

    private var canSendInput: Bool {
        inputEnabled && window?.isKeyWindow == true && window?.windowScene?.activationState == .foregroundActive
    }

    private var videoRect: CGRect {
        guard videoSize.width > 0, videoSize.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        return AVMakeRect(aspectRatio: videoSize, insideRect: bounds)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isMultipleTouchEnabled = true
        clipsToBounds = true
        accessibilityLabel = "Remote display"
        accessibilityHint = "Tap to click. Drag with one finger. Tap with two fingers to right-click. Drag with two fingers to scroll."

        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        let secondaryTap = UITapGestureRecognizer(target: self, action: #selector(secondaryTapped(_:)))
        secondaryTap.numberOfTouchesRequired = 2
        let drag = UIPanGestureRecognizer(target: self, action: #selector(dragged(_:)))
        drag.maximumNumberOfTouches = 1
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(scrolled(_:)))
        scroll.minimumNumberOfTouches = 2
        scroll.maximumNumberOfTouches = 2

        for gesture in [tap, secondaryTap, drag, scroll] {
            gesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue),
                                         NSNumber(value: UITouch.TouchType.pencil.rawValue)]
            gesture.delegate = self
            addGestureRecognizer(gesture)
        }
        tap.require(toFail: secondaryTap)
        tap.require(toFail: drag)
        secondaryTap.require(toFail: scroll)

        let pointerScroll = UIPanGestureRecognizer(target: self, action: #selector(scrolled(_:)))
        pointerScroll.allowedTouchTypes = []
        pointerScroll.allowedScrollTypesMask = .all
        pointerScroll.delegate = self
        addGestureRecognizer(pointerScroll)

        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:)))
        hover.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        addGestureRecognizer(hover)
        pointerInteraction = UIPointerInteraction(delegate: self)
        addInteraction(pointerInteraction)

        NotificationCenter.default.addObserver(self, selector: #selector(applicationDeactivated),
                                               name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(sceneDeactivated(_:)),
                                               name: UIScene.willDeactivateNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(windowResignedKey(_:)),
                                               name: UIWindow.didResignKeyNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    func configure(renderer: VideoRenderer, videoSize: CGSize, displayID: UInt32, inputEnabled: Bool,
                   inputResetGeneration: UInt64,
                   onInput: @escaping (InputMessage) -> Void, onFocusLost: @escaping () -> Void) {
        let changesTarget = self.renderer !== renderer || self.displayID != displayID
        let resetsInput = self.inputResetGeneration != inputResetGeneration
        if changesTarget || resetsInput || (self.inputEnabled && !inputEnabled) {
            releaseEverything()
            for gesture in gestureRecognizers ?? [] { gesture.isEnabled = false }
        }
        if self.renderer !== renderer {
            self.renderer?.displayLayer.removeFromSuperlayer()
            self.renderer = renderer
            layer.addSublayer(renderer.displayLayer)
            setNeedsLayout()
        }
        let shouldFocus = inputEnabled && !self.inputEnabled
        self.videoSize = videoSize
        self.displayID = displayID
        self.onInput = onInput
        self.onFocusLost = onFocusLost
        self.inputEnabled = inputEnabled
        self.inputResetGeneration = inputResetGeneration
        for gesture in gestureRecognizers ?? [] where gesture.isEnabled != inputEnabled {
            gesture.isEnabled = inputEnabled
        }
        if shouldFocus, canSendInput { becomeFirstResponder() }
        if !inputEnabled, isFirstResponder { _ = resignFirstResponder() }
        pointerInteraction.invalidate()
    }

    func detach() {
        releaseEverything()
        renderer?.displayLayer.removeFromSuperlayer()
        renderer = nil
        onInput = nil
        onFocusLost = nil
        inputEnabled = false
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        renderer?.displayLayer.frame = bounds
        CATransaction.commit()
        pointerInteraction.invalidate()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { lostFocus() }
        else if canSendInput { becomeFirstResponder() }
    }

    override var canBecomeFirstResponder: Bool { inputEnabled }

    override func resignFirstResponder() -> Bool {
        let wasFirstResponder = isFirstResponder
        let resigned = super.resignFirstResponder()
        if wasFirstResponder && resigned { lostFocus() }
        return resigned
    }

    @objc private func applicationDeactivated() { lostFocus() }

    @objc private func sceneDeactivated(_ notification: Notification) {
        if let scene = notification.object as? UIScene, scene === window?.windowScene { lostFocus() }
    }

    @objc private func windowResignedKey(_ notification: Notification) {
        if let window = notification.object as? UIWindow, window === self.window { lostFocus() }
    }

    private func lostFocus() {
        releaseEverything()
        // Cancel ongoing drags so reactivation cannot resume a partially released gesture.
        for gesture in gestureRecognizers ?? [] {
            gesture.isEnabled = false
            gesture.isEnabled = inputEnabled
        }
        onFocusLost?()
    }

    private func emit(_ messages: [InputMessage]) {
        for message in messages { onInput?(message) }
    }

    private func releaseEverything() {
        emit(keyboard.releaseAll())
        for button in heldButtons.sorted(by: { $0.rawValue < $1.rawValue }) {
            onInput?(.button(button, down: false))
        }
        heldButtons.removeAll()
        pointerSequenceActive = false
        scrollRemainder = .zero
    }

    // MARK: Touch gestures

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // Hover may enter through a letterbox margin and subsequently move into the picture.
        if gestureRecognizer is UIHoverGestureRecognizer { return true }
        return canSendInput && videoRect.contains(gestureRecognizer.location(in: self))
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        click(.left, at: gesture.location(in: self))
    }

    @objc private func secondaryTapped(_ gesture: UITapGestureRecognizer) {
        click(.right, at: gesture.location(in: self))
    }

    private func click(_ button: InputMessage.PointerButton, at point: CGPoint) {
        guard canSendInput, movePointer(to: point) else { return }
        becomeFirstResponder()
        setButton(button, down: true)
        setButton(button, down: false)
    }

    @objc private func dragged(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            guard canSendInput else { return }
            becomeFirstResponder()
            let point = gesture.location(in: self)
            let translation = gesture.translation(in: self)
            // Press where the gesture began, before moving to its current position.
            guard movePointer(to: CGPoint(x: point.x - translation.x, y: point.y - translation.y)) else { return }
            setButton(.left, down: true)
            _ = movePointer(to: point, clamp: true)
        case .changed:
            guard heldButtons.contains(.left) else { return }
            _ = movePointer(to: gesture.location(in: self), clamp: true)
        case .ended:
            if heldButtons.contains(.left) { _ = movePointer(to: gesture.location(in: self), clamp: true) }
            setButton(.left, down: false)
        case .cancelled, .failed:
            setButton(.left, down: false)
        default: break
        }
    }

    @objc private func scrolled(_ gesture: UIPanGestureRecognizer) {
        guard canSendInput else { return }
        switch gesture.state {
        case .began:
            scrollRemainder = .zero
            becomeFirstResponder()
            _ = movePointer(to: gesture.location(in: self))
        case .changed, .ended: break
        default: return
        }
        let translation = gesture.translation(in: self)
        gesture.setTranslation(.zero, in: self)
        let rect = videoRect
        guard rect.width > 0, rect.height > 0 else { return }
        let x = translation.x * videoSize.width / rect.width + scrollRemainder.x
        let y = translation.y * videoSize.height / rect.height + scrollRemainder.y
        let dx = x.rounded(.towardZero)
        let dy = y.rounded(.towardZero)
        scrollRemainder = CGPoint(x: x - dx, y: y - dy)
        guard dx != 0 || dy != 0 else { return }
        onInput?(.scroll(dx: Int16(clamping: Int(dx)), dy: Int16(clamping: Int(dy)), units: .pixels))
    }

    // MARK: Mouse and trackpad

    @objc private func hovered(_ gesture: UIHoverGestureRecognizer) {
        guard gesture.state == .began || gesture.state == .changed else { return }
        _ = movePointer(to: gesture.location(in: self))
    }

    @discardableResult
    private func movePointer(to point: CGPoint, clamp: Bool = false) -> Bool {
        guard canSendInput else { return false }
        let rect = videoRect
        guard rect.width > 0, rect.height > 0, clamp || rect.contains(point) else { return false }
        let x = min(max((point.x - rect.minX) / rect.width, 0), 1)
        let y = min(max((point.y - rect.minY) / rect.height, 0), 1)
        onInput?(.pointer(x: UInt16((x * 65535).rounded()), y: UInt16((y * 65535).rounded()), display: displayID))
        return true
    }

    private func setButton(_ button: InputMessage.PointerButton, down: Bool) {
        if down {
            guard canSendInput, heldButtons.insert(button).inserted else { return }
        } else {
            guard heldButtons.remove(button) != nil else { return }
        }
        onInput?(.button(button, down: down))
    }

    private func updatePointerTouches(_ touches: Set<UITouch>, event: UIEvent?, starting: Bool = false, ending: Bool = false) {
        guard let touch = touches.first(where: { $0.type == .indirectPointer }) else { return }
        guard starting || pointerSequenceActive else { return }
        let wasDragging = !heldButtons.isEmpty
        guard canSendInput, movePointer(to: touch.location(in: self), clamp: wasDragging) else {
            if ending { releaseEverything() }
            return
        }
        if starting { pointerSequenceActive = true }
        if !ending { becomeFirstResponder() }
        // UIKit reports the currently held physical buttons, including secondary and middle.
        let mask = event?.buttonMask ?? []
        for (index, button) in InputMessage.PointerButton.allCases.enumerated() {
            let down = mask.rawValue & (1 << index) != 0
            // Never begin a new button press from the final touch of an interrupted sequence.
            if !ending || heldButtons.contains(button) { setButton(button, down: down) }
        }
        if ending { pointerSequenceActive = !mask.isEmpty }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        updatePointerTouches(touches, event: event, starting: true)
        super.touchesBegan(touches, with: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        updatePointerTouches(touches, event: event)
        super.touchesMoved(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        updatePointerTouches(touches, event: event, ending: true)
        super.touchesEnded(touches, with: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if touches.contains(where: { $0.type == .indirectPointer }) { releaseEverything() }
        super.touchesCancelled(touches, with: event)
    }

    func pointerInteraction(_ interaction: UIPointerInteraction, regionFor request: UIPointerRegionRequest,
                            defaultRegion: UIPointerRegion) -> UIPointerRegion? {
        guard canSendInput, videoRect.contains(request.location) else { return nil }
        return UIPointerRegion(rect: videoRect)
    }

    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        // The host composites its cursor into the video frame.
        canSendInput ? .hidden() : nil
    }

    // MARK: Hardware keyboard

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard canSendInput, isFirstResponder else { super.pressesBegan(presses, with: event); return }
        var unhandled = Set<UIPress>()
        // A batch may contain a modifier and an ordinary key together. Record the physical
        // modifier first, so reconciliation does not synthesize its opposite-side counterpart.
        let ordered = presses.sorted {
            ($0.key?.keyCode.rawValue ?? 0) > ($1.key?.keyCode.rawValue ?? 0)
        }
        for press in ordered {
            guard let key = press.key, let usage = UInt16(exactly: key.keyCode.rawValue), usage > 0 else {
                unhandled.insert(press)
                continue
            }
            // UIKit's independent modifier bits match CGEventFlags. Preserve the side from raw HID events.
            if KeyMap.modifier(forUsage: usage) == nil {
                emit(keyboard.synchronizeModifiers(flags: UInt64(key.modifierFlags.rawValue)))
            }
            emit(keyboard.key(usage, down: true, isRepeat: keyboard.held.contains(usage)))
        }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()
        for press in presses {
            guard let key = press.key, let usage = UInt16(exactly: key.keyCode.rawValue), keyboard.held.contains(usage) else {
                unhandled.insert(press)
                continue
            }
            emit(keyboard.key(usage, down: false))
        }
        if !unhandled.isEmpty { super.pressesEnded(unhandled, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        emit(keyboard.releaseAll())
        super.pressesCancelled(presses, with: event)
    }
}
