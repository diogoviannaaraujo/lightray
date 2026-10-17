import AVFoundation
import LightrayCore
import SwiftUI
import UIKit

/// The shared low-latency renderer, with iPad touch and physical input translated to host input.
/// Fingers work as a touchpad and pinch to zoom; a mouse, trackpad or Pencil points directly.
struct StreamSurface: UIViewRepresentable {
    let renderer: VideoRenderer
    var videoSize: CGSize
    var displayID: UInt32 = 0
    var inputEnabled = true
    var inputResetGeneration: UInt64 = 0
    var zoomResetGeneration: UInt64 = 0
    var softwareKeyboardVisible = false
    var onInput: (InputMessage) -> Void
    var onFocusLost: () -> Void = {}
    var onKeyboardDismissed: () -> Void = {}
    var onZoomedChange: (Bool) -> Void = { _ in }
    var onTouch: () -> Void = {}

    func makeUIView(context: Context) -> StreamSurfaceView {
        let view = StreamSurfaceView(frame: .zero)
        updateUIView(view, context: context)
        return view
    }

    func updateUIView(_ view: StreamSurfaceView, context: Context) {
        view.configure(renderer: renderer, videoSize: videoSize, displayID: displayID,
                       inputEnabled: inputEnabled, inputResetGeneration: inputResetGeneration,
                       zoomResetGeneration: zoomResetGeneration,
                       softwareKeyboardVisible: softwareKeyboardVisible,
                       onInput: onInput, onFocusLost: onFocusLost,
                       onKeyboardDismissed: onKeyboardDismissed,
                       onZoomedChange: onZoomedChange, onTouch: onTouch)
    }

    static func dismantleUIView(_ view: StreamSurfaceView, coordinator: ()) {
        view.detach()
    }
}

@MainActor
final class StreamSurfaceView: UIView, UIKeyInput, UIGestureRecognizerDelegate, UIPointerInteractionDelegate {
    private enum TwoFingerMode { case undecided, zoom, scroll }
    /// How far two fingers must drag, or a pinch scale (as a logarithm), before deciding which it is.
    private static let scrollDecisionDistance: CGFloat = 20
    private static let zoomDecisionScale: CGFloat = 0.1

    private var renderer: VideoRenderer?
    private var videoSize = CGSize.zero
    private var displayID: UInt32 = 0
    private var inputEnabled = false
    private var inputResetGeneration: UInt64 = 0
    private var zoomResetGeneration: UInt64 = 0
    private var onInput: ((InputMessage) -> Void)?
    private var onFocusLost: (() -> Void)?
    private var onKeyboardDismissed: (() -> Void)?
    private var onZoomedChange: ((Bool) -> Void)?
    private var onTouch: (() -> Void)?
    private(set) var softwareKeyboardVisible = false
    private let hiddenKeyboard = UIView(frame: .zero)
    private var keyboard = RemoteKeyboard()
    private var heldButtons = Set<InputMessage.PointerButton>()
    private var pointerSequenceActive = false
    private var scrollRemainder = CGPoint.zero
    private var pointerInteraction: UIPointerInteraction!

    /// Where this client last put the host's cursor, which the host draws into the picture.
    private(set) var cursor = CGPoint(x: 0.5, y: 0.5)
    private var cursorSynced = false
    private(set) var zoom: CGFloat = 1
    /// Where the whole picture is shown, beyond the surface's edges once zoomed.
    private(set) var contentFrame = CGRect.zero
    private var followMode = RemoteViewport.Follow.center
    /// Pencil moves the cursor without moving the picture, and so does a change of follow mode;
    /// the next update animates to catch up.
    private var viewportStale = false
    private var reportedZoomed: Bool?
    private var tapDrag = TapDrag()
    private var releaseTask: Task<Void, Never>?
    private var twoFingerMode = TwoFingerMode.undecided
    private var pendingScroll = CGPoint.zero
    private var pinchStartZoom: CGFloat = 1

    private let touchScroll = UIPanGestureRecognizer()
    private let touchPinch = UIPinchGestureRecognizer()
    private let pencilTap = UITapGestureRecognizer()
    private let pencilDrag = UIPanGestureRecognizer()
    private let pointerScroll = UIPanGestureRecognizer()
    private let pointerPinch = UIPinchGestureRecognizer()

    private var canSendInput: Bool {
        inputEnabled && window?.isKeyWindow == true && window?.windowScene?.activationState == .foregroundActive
    }

    private var viewport: RemoteViewport {
        RemoteViewport(bounds: bounds.size, videoSize: videoSize, zoom: zoom)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isMultipleTouchEnabled = true
        clipsToBounds = true
        accessibilityLabel = "Remote display"
        accessibilityHint = "Works as a touchpad. Drag to move the pointer, tap to click, tap with two fingers to right-click, double-tap and drag to drag, drag with two fingers to scroll, and pinch to zoom."

        let fingers = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        let secondaryTap = UITapGestureRecognizer(target: self, action: #selector(secondaryTapped(_:)))
        secondaryTap.numberOfTouchesRequired = 2
        let move = UIPanGestureRecognizer(target: self, action: #selector(touchpadMoved(_:)))
        move.maximumNumberOfTouches = 1
        touchScroll.addTarget(self, action: #selector(touchScrolled(_:)))
        touchScroll.minimumNumberOfTouches = 2
        touchScroll.maximumNumberOfTouches = 2
        touchPinch.addTarget(self, action: #selector(pinched(_:)))
        for gesture in [tap, secondaryTap, move, touchScroll, touchPinch] {
            gesture.allowedTouchTypes = fingers
            gesture.delegate = self
            addGestureRecognizer(gesture)
        }
        tap.require(toFail: secondaryTap)
        tap.require(toFail: move)
        secondaryTap.require(toFail: touchScroll)
        secondaryTap.require(toFail: touchPinch)

        pencilTap.addTarget(self, action: #selector(pencilTapped(_:)))
        pencilDrag.addTarget(self, action: #selector(pencilDragged(_:)))
        pencilDrag.maximumNumberOfTouches = 1
        for gesture in [pencilTap, pencilDrag] {
            gesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
            gesture.delegate = self
            addGestureRecognizer(gesture)
        }
        pencilTap.require(toFail: pencilDrag)

        pointerScroll.addTarget(self, action: #selector(pointerScrolled(_:)))
        pointerScroll.allowedTouchTypes = []
        pointerScroll.allowedScrollTypesMask = .all
        pointerPinch.addTarget(self, action: #selector(pinched(_:)))
        pointerPinch.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        for gesture in [pointerScroll, pointerPinch] {
            gesture.delegate = self
            addGestureRecognizer(gesture)
        }

        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:)))
        hover.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        addGestureRecognizer(hover)
        pointerInteraction = UIPointerInteraction(delegate: self)
        addInteraction(pointerInteraction)
        inputAssistantItem.leadingBarButtonGroups = []
        inputAssistantItem.trailingBarButtonGroups = []

        NotificationCenter.default.addObserver(self, selector: #selector(keyboardDidHide),
                                               name: UIResponder.keyboardDidHideNotification, object: nil)

        NotificationCenter.default.addObserver(self, selector: #selector(applicationDeactivated),
                                               name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(sceneDeactivated(_:)),
                                               name: UIScene.willDeactivateNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(windowResignedKey(_:)),
                                               name: UIWindow.didResignKeyNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    func configure(renderer: VideoRenderer, videoSize: CGSize, displayID: UInt32, inputEnabled: Bool,
                   inputResetGeneration: UInt64, zoomResetGeneration: UInt64 = 0,
                   softwareKeyboardVisible: Bool = false,
                   onInput: @escaping (InputMessage) -> Void, onFocusLost: @escaping () -> Void,
                   onKeyboardDismissed: @escaping () -> Void = {},
                   onZoomedChange: @escaping (Bool) -> Void = { _ in }, onTouch: @escaping () -> Void = {}) {
        let changesTarget = self.renderer !== renderer || self.displayID != displayID
        let resetsInput = self.inputResetGeneration != inputResetGeneration
        let resetsView = changesTarget || self.videoSize != videoSize
        let resetsZoom = resetsView || self.zoomResetGeneration != zoomResetGeneration
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
        self.onKeyboardDismissed = onKeyboardDismissed
        self.onZoomedChange = onZoomedChange
        self.onTouch = onTouch
        self.inputEnabled = inputEnabled
        self.inputResetGeneration = inputResetGeneration
        self.zoomResetGeneration = zoomResetGeneration
        if resetsView {
            // Nothing says where the host's cursor is now; start from the middle.
            cursor = CGPoint(x: 0.5, y: 0.5)
            cursorSynced = false
            followMode = .center
        }
        if resetsZoom { setZoom(1, animated: !resetsView) } else { reportZoom() }
        for gesture in gestureRecognizers ?? [] where gesture.isEnabled != inputEnabled {
            gesture.isEnabled = inputEnabled
        }
        setSoftwareKeyboardVisible(softwareKeyboardVisible && inputEnabled)
        if shouldFocus, canSendInput { becomeFirstResponder() }
        if !inputEnabled, isFirstResponder { _ = resignFirstResponder() }
        pointerInteraction.invalidate()
    }

    func detach() {
        setSoftwareKeyboardVisible(false)
        _ = resignFirstResponder()
        releaseEverything()
        renderer?.displayLayer.removeFromSuperlayer()
        renderer = nil
        onInput = nil
        onFocusLost = nil
        onKeyboardDismissed = nil
        onZoomedChange = nil
        onTouch = nil
        inputEnabled = false
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if let displayLayer = renderer?.displayLayer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            // The layer carries the zoom transform, so set its size and place rather than its frame.
            displayLayer.bounds = CGRect(origin: .zero, size: bounds.size)
            displayLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
            CATransaction.commit()
        }
        applyViewport()
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
        if softwareKeyboardVisible {
            setSoftwareKeyboardVisible(false)
            onKeyboardDismissed?()
        }
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
        releaseTask?.cancel()
        releaseTask = nil
        tapDrag = TapDrag()
        twoFingerMode = .undecided
        pendingScroll = .zero
        emit(keyboard.releaseAll())
        for button in heldButtons.sorted(by: { $0.rawValue < $1.rawValue }) {
            onInput?(.button(button, down: false))
        }
        heldButtons.removeAll()
        pointerSequenceActive = false
        scrollRemainder = .zero
    }

    // MARK: Onscreen keyboard

    // Keep first-responder status for hardware keys while suppressing the software keyboard.
    override var inputView: UIView? { softwareKeyboardVisible ? nil : hiddenKeyboard }
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var autocorrectionType: UITextAutocorrectionType = .no
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no

    // The document lives on the host, so Backspace must remain available even before typing.
    var hasText: Bool { true }

    func setSoftwareKeyboardVisible(_ visible: Bool) {
        guard softwareKeyboardVisible != visible else { return }
        softwareKeyboardVisible = visible
        if visible, canSendInput { becomeFirstResponder() }
        if isFirstResponder { reloadInputViews() }
    }

    @objc private func keyboardDidHide() {
        // Also follow the keyboard's own dismiss button, without dismissing a replacement
        // responder's keyboard when this surface is removed.
        guard softwareKeyboardVisible else { return }
        setSoftwareKeyboardVisible(false)
        onKeyboardDismissed?()
    }

    func insertText(_ text: String) {
        guard softwareKeyboardVisible, canSendInput, isFirstResponder else { return }
        for character in text {
            switch character {
            case "\n", "\r", "\r\n": tapKey(0x28)
            case "\t": tapKey(0x2B)
            default:
                // Scalar-sized messages also bound large dictation/paste callbacks, without
                // truncating a UTF-8 character or assuming the host's keyboard layout.
                for scalar in character.unicodeScalars { onInput?(.text(String(scalar))) }
            }
        }
    }

    func deleteBackward() {
        guard softwareKeyboardVisible, canSendInput, isFirstResponder else { return }
        tapKey(0x2A)
    }

    private func tapKey(_ usage: UInt16) {
        guard !keyboard.held.contains(usage) else { return }
        emit(keyboard.key(usage, down: true))
        emit(keyboard.key(usage, down: false))
    }

    // MARK: Cursor and zoom

    /// Moves the picture to follow the cursor, as the most recent kind of input wants.
    private func applyViewport(animated: Bool = false) {
        let viewport = viewport
        contentFrame = viewport.contentFrame(cursor: cursor, follow: followMode)
        viewportStale = false
        guard let displayLayer = renderer?.displayLayer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        displayLayer.setAffineTransform(viewport.transform(for: contentFrame))
        CATransaction.commit()
    }

    private func setFollowMode(_ mode: RemoteViewport.Follow) {
        guard followMode != mode else { return }
        followMode = mode
        viewportStale = true
    }

    private func follow(_ mode: RemoteViewport.Follow) {
        setFollowMode(mode)
        applyViewport(animated: viewportStale && zoom > 1)
    }

    /// Zooms around the cursor, from 1× (the whole display) to `RemoteViewport.maximumZoom`.
    func setZoom(_ value: CGFloat, animated: Bool = false) {
        zoom = RemoteViewport.clampedZoom(value)
        applyViewport(animated: animated || viewportStale)
        pointerInteraction.invalidate()
        reportZoom()
    }

    private func reportZoom() {
        let zoomed = zoom > 1
        guard reportedZoomed != zoomed else { return }
        reportedZoomed = zoomed
        // SwiftUI may be updating this view; report once it has finished.
        Task { [weak self] in self?.onZoomedChange?(zoomed) }
    }

    private func sendCursor() {
        guard canSendInput else { return }
        cursorSynced = true
        onInput?(.pointer(x: UInt16((cursor.x * 65535).rounded()), y: UInt16((cursor.y * 65535).rounded()),
                          display: displayID))
    }

    /// The host's cursor may be anywhere until this client first places it.
    private func syncCursor() {
        if !cursorSynced { sendCursor() }
    }

    /// Touchpad movement: moves the cursor by a finger's translation, keeping it centred when zoomed.
    func moveCursor(by translation: CGPoint, speed: CGFloat = 0) {
        guard canSendInput else { return }
        let delta = viewport.hostDelta(forTranslation: translation, speed: speed)
        cursor = CGPoint(x: min(max(cursor.x + delta.dx, 0), 1), y: min(max(cursor.y + delta.dy, 0), 1))
        follow(.center)
        sendCursor()
    }

    /// Pencil: points at the picture where it touches, without moving the picture under it.
    @discardableResult
    private func pointDirectly(at point: CGPoint, clamp: Bool = false) -> Bool {
        guard canSendInput, let host = RemoteViewport.hostPoint(at: point, in: contentFrame, clamp: clamp) else {
            return false
        }
        cursor = host
        viewportStale = true
        sendCursor()
        return true
    }

    /// Mouse and trackpad: the whole surface spans the display, and a zoomed picture pans with
    /// the pointer so the cursor stays under it.
    @discardableResult
    private func pointWithMouse(at point: CGPoint, clamp: Bool = false) -> Bool {
        guard canSendInput, let host = viewport.hostPoint(forPointerAt: point, clamp: clamp) else { return false }
        cursor = host
        follow(.proportional)
        sendCursor()
        return true
    }

    // MARK: Touchpad

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // Hover may enter through a letterbox margin and subsequently move into the picture.
        if gestureRecognizer is UIHoverGestureRecognizer { return true }
        guard canSendInput else { return false }
        let location = gestureRecognizer.location(in: self)
        if gestureRecognizer === pencilTap || gestureRecognizer === pencilDrag {
            return contentFrame.contains(location)
        }
        if gestureRecognizer === pointerScroll { return viewport.hostPoint(forPointerAt: location) != nil }
        // Fingers can use the whole surface, letterbox included.
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // Two fingers both pinch and drag; whichever passes its threshold first decides.
        let pair = [gestureRecognizer, other]
        return pair.contains(touchPinch) && pair.contains(touchScroll)
    }

    private func perform(_ actions: [TapDrag.Action]) {
        for action in actions {
            switch action {
            case .press: setButton(.left, down: true)
            case .release: setButton(.left, down: false)
            case .cancelRelease:
                releaseTask?.cancel()
                releaseTask = nil
            case .scheduleRelease:
                releaseTask?.cancel()
                releaseTask = Task { [weak self] in
                    do { try await Task.sleep(for: TapDrag.holdInterval) } catch { return }
                    guard let self else { return }
                    self.perform(self.tapDrag.handle(.releaseTimer))
                }
            }
        }
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        guard canSendInput else { return }
        becomeFirstResponder()
        syncCursor()
        perform(tapDrag.handle(.tap))
    }

    @objc private func secondaryTapped(_ gesture: UITapGestureRecognizer) {
        guard canSendInput else { return }
        becomeFirstResponder()
        perform(tapDrag.handle(.otherGesture))
        syncCursor()
        setButton(.right, down: true)
        setButton(.right, down: false)
    }

    @objc private func touchpadMoved(_ gesture: UIPanGestureRecognizer) {
        let state = gesture.state
        guard state == .began || state == .changed || state == .ended else {
            if state == .cancelled || state == .failed { perform(tapDrag.handle(.dragEnded)) }
            return
        }
        if canSendInput {
            if state == .began {
                becomeFirstResponder()
                // After a tap, this keeps its button held for the drag.
                perform(tapDrag.handle(.dragBegan))
            }
            let translation = gesture.translation(in: self)
            gesture.setTranslation(.zero, in: self)
            let velocity = gesture.velocity(in: self)
            moveCursor(by: translation, speed: hypot(velocity.x, velocity.y))
        }
        if state == .ended { perform(tapDrag.handle(.dragEnded)) }
    }

    @objc private func touchScrolled(_ gesture: UIPanGestureRecognizer) {
        guard canSendInput else { return }
        switch gesture.state {
        case .began:
            if !touchPinch.isActive { twoFingerMode = .undecided }
            pendingScroll = .zero
            scrollRemainder = .zero
            becomeFirstResponder()
        case .changed, .ended: break
        default: return
        }
        let translation = gesture.translation(in: self)
        gesture.setTranslation(.zero, in: self)
        switch twoFingerMode {
        case .zoom: break
        case .scroll: scroll(by: translation)
        case .undecided:
            pendingScroll.x += translation.x
            pendingScroll.y += translation.y
            guard hypot(pendingScroll.x, pendingScroll.y) > Self.scrollDecisionDistance else { return }
            twoFingerMode = .scroll
            perform(tapDrag.handle(.otherGesture))
            syncCursor()
            scroll(by: pendingScroll)
            pendingScroll = .zero
        }
    }

    @objc private func pinched(_ gesture: UIPinchGestureRecognizer) {
        let touch = gesture === touchPinch
        switch gesture.state {
        case .began:
            pinchStartZoom = zoom
            if touch, !touchScroll.isActive { twoFingerMode = .undecided }
        case .changed: break
        case .ended, .cancelled:
            // Settle a pinch that barely left the whole display.
            if zoom > 1, zoom < 1.05 { setZoom(1, animated: true) }
            return
        default: return
        }
        if touch {
            switch twoFingerMode {
            case .scroll: return
            case .zoom: break
            case .undecided:
                guard abs(log(gesture.scale)) > Self.zoomDecisionScale else { return }
                twoFingerMode = .zoom
                perform(tapDrag.handle(.otherGesture))
            }
        }
        // Zoom centres on the cursor wherever the pinch is.
        setFollowMode(touch ? .center : .proportional)
        setZoom(pinchStartZoom * gesture.scale)
    }

    private func scroll(by translation: CGPoint) {
        let size = viewport.contentSize
        guard size.width > 0, size.height > 0 else { return }
        // Scroll the host by as many pixels as the fingers cross on the picture as shown.
        let x = translation.x * videoSize.width / size.width + scrollRemainder.x
        let y = translation.y * videoSize.height / size.height + scrollRemainder.y
        let dx = x.rounded(.towardZero)
        let dy = y.rounded(.towardZero)
        scrollRemainder = CGPoint(x: x - dx, y: y - dy)
        guard dx != 0 || dy != 0 else { return }
        onInput?(.scroll(dx: Int16(clamping: Int(dx)), dy: Int16(clamping: Int(dy)), units: .pixels))
    }

    /// A touch that lands while a tap holds the button, then lifts without dragging or tapping,
    /// lets go. Recognisers for the same touch act first, so a second tap still makes a double click.
    private func directTouchesEnded(_ touches: Set<UITouch>, event: UIEvent?) {
        guard tapDrag.state == .armed, touches.contains(where: { $0.type == .direct }) else { return }
        let fingerDown = event?.allTouches?.contains {
            $0.type == .direct && $0.phase != .ended && $0.phase != .cancelled
        } ?? false
        guard !fingerDown else { return }
        Task { [weak self] in
            guard let self else { return }
            self.perform(self.tapDrag.handle(.touchesEndedWithoutGesture))
        }
    }

    // MARK: Pencil

    @objc private func pencilTapped(_ gesture: UITapGestureRecognizer) {
        guard canSendInput, pointDirectly(at: gesture.location(in: self)) else { return }
        becomeFirstResponder()
        setButton(.left, down: true)
        setButton(.left, down: false)
    }

    @objc private func pencilDragged(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            guard canSendInput else { return }
            becomeFirstResponder()
            let point = gesture.location(in: self)
            let translation = gesture.translation(in: self)
            // Press where the gesture began, before moving to its current position.
            guard pointDirectly(at: CGPoint(x: point.x - translation.x, y: point.y - translation.y)) else { return }
            setButton(.left, down: true)
            pointDirectly(at: point, clamp: true)
        case .changed:
            guard heldButtons.contains(.left) else { return }
            pointDirectly(at: gesture.location(in: self), clamp: true)
        case .ended:
            if heldButtons.contains(.left) { pointDirectly(at: gesture.location(in: self), clamp: true) }
            setButton(.left, down: false)
        case .cancelled, .failed:
            setButton(.left, down: false)
        default: break
        }
    }

    // MARK: Mouse and trackpad

    @objc private func hovered(_ gesture: UIHoverGestureRecognizer) {
        guard gesture.state == .began || gesture.state == .changed else { return }
        pointWithMouse(at: gesture.location(in: self))
    }

    @objc private func pointerScrolled(_ gesture: UIPanGestureRecognizer) {
        guard canSendInput else { return }
        switch gesture.state {
        case .began:
            scrollRemainder = .zero
            becomeFirstResponder()
            pointWithMouse(at: gesture.location(in: self))
        case .changed, .ended: break
        default: return
        }
        let translation = gesture.translation(in: self)
        gesture.setTranslation(.zero, in: self)
        scroll(by: translation)
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
        guard canSendInput, pointWithMouse(at: touch.location(in: self), clamp: wasDragging) else {
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
        onTouch?()
        if canSendInput, touches.contains(where: { $0.type == .direct }) { perform(tapDrag.handle(.touchDown)) }
        updatePointerTouches(touches, event: event, starting: true)
        super.touchesBegan(touches, with: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        updatePointerTouches(touches, event: event)
        super.touchesMoved(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        updatePointerTouches(touches, event: event, ending: true)
        directTouchesEnded(touches, event: event)
        super.touchesEnded(touches, with: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if touches.contains(where: { $0.type == .indirectPointer }) { releaseEverything() }
        directTouchesEnded(touches, event: event)
        super.touchesCancelled(touches, with: event)
    }

    func pointerInteraction(_ interaction: UIPointerInteraction, regionFor request: UIPointerRegionRequest,
                            defaultRegion: UIPointerRegion) -> UIPointerRegion? {
        guard canSendInput, viewport.hostPoint(forPointerAt: request.location) != nil else { return nil }
        return UIPointerRegion(rect: contentFrame.intersection(bounds))
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

private extension UIGestureRecognizer {
    var isActive: Bool { state == .began || state == .changed }
}
