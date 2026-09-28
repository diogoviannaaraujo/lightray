import AppKit
import CoreGraphics
import LightrayCore
import LightrayMac

/// Delivers input messages as CGEvents. A pointer position lands on the display it names. It
/// tracks everything it holds down for the client, so that a session ending releases it all, and
/// it ignores a release of anything it does not hold.
final class Injector {
    enum Mode { case inject, log, off }

    let mode: Mode
    /// With the test pattern, whose displays are not real, every position lands on the main display.
    let testPattern: Bool
    private let source = CGEventSource(stateID: .hidSystemState)
    private var heldKeys = Set<UInt16>()
    private var modifiers = Set<KeyMap.Modifier>()
    private var capsLock = false
    private var buttons = Set<InputMessage.PointerButton>()
    private var position: CGPoint
    private var lastClick: (button: InputMessage.PointerButton, time: TimeInterval, at: CGPoint, count: Int)?
    private var wheelRemainder = (x: 0, y: 0)

    init(mode: Mode, testPattern: Bool) {
        self.mode = mode
        self.testPattern = testPattern
        let main = CGDisplayBounds(CGMainDisplayID())
        position = CGPoint(x: main.midX, y: main.midY)
    }

    func handle(_ message: InputMessage, displays: [DisplayInfo]) {
        switch mode {
        case .off: return
        case .log: log("input: \(message)")
        case .inject: break
        }
        switch message {
        case .key(let usage, let down, let isRepeat): key(usage, down: down, isRepeat: isRepeat)
        case .pointer(let x, let y, let display):
            // A position on a display the host does not have is ignored.
            guard let bounds = bounds(of: display, in: displays) else { return }
            move(to: point(x, y, in: bounds))
        case .button(let button, let down): self.button(button, down: down)
        case .scroll(let dx, let dy, let units): scroll(dx: dx, dy: dy, units: units)
        }
    }

    /// The input reset: releases every key and button held on the client's behalf.
    func reset() {
        for usage in heldKeys { key(usage, down: false, isRepeat: false) }
        for usage in UInt16(0xE0)...0xE7 { key(usage, down: false, isRepeat: false) }
        for button in buttons { self.button(button, down: false) }
        heldKeys.removeAll()
        modifiers.removeAll()
        buttons.removeAll()
    }

    // MARK: Keyboard

    private func flags(for usage: UInt16?) -> CGEventFlags {
        var raw: UInt64 = 0x100  // NX_NONCOALSESCEDMASK, as the keyboard driver sets it.
        for modifier in modifiers { raw |= KeyMap.flag(modifier) | KeyMap.deviceMask(modifier) }
        if capsLock { raw |= CGEventFlags.maskAlphaShift.rawValue }
        if let usage {
            if KeyMap.isNumericPad(usage) { raw |= CGEventFlags.maskNumericPad.rawValue }
            if KeyMap.isFunctionCluster(usage) { raw |= CGEventFlags.maskSecondaryFn.rawValue }
        }
        return CGEventFlags(rawValue: raw)
    }

    private func key(_ usage: UInt16, down: Bool, isRepeat: Bool) {
        guard let code = KeyMap.keyCode(forUsage: usage) else { return }
        if usage == KeyMap.capsLockUsage {
            // Caps Lock toggles on press; a posted key does not reach the lock itself, so the
            // state rides on every event's flags instead.
            guard down, !isRepeat else { return }
            capsLock.toggle()
            post(keyCode: code, down: true, type: .flagsChanged, usage: usage)
            return
        }
        if let modifier = KeyMap.modifier(forUsage: usage) {
            if down {
                modifiers.insert(modifier)
            } else if modifiers.remove(modifier) == nil {
                return
            }
            post(keyCode: code, down: down, type: .flagsChanged, usage: usage)
            return
        }
        if down {
            heldKeys.insert(usage)
        } else if heldKeys.remove(usage) == nil {
            return
        }
        post(keyCode: code, down: down, type: nil, usage: usage, isRepeat: isRepeat)
    }

    private func post(keyCode: UInt16, down: Bool, type: CGEventType?, usage: UInt16, isRepeat: Bool = false) {
        guard mode == .inject, let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down)
        else { return }
        if let type { event.type = type }
        event.flags = flags(for: usage)
        if isRepeat { event.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
        event.post(tap: .cghidEventTap)
    }

    // MARK: Pointer

    /// The display's rectangle in global coordinates; 0 means the primary display.
    private func bounds(of display: UInt32, in displays: [DisplayInfo]) -> CGRect? {
        if testPattern || display == 0 { return CGDisplayBounds(CGMainDisplayID()) }
        guard displays.contains(where: { $0.id == display }) else { return nil }
        return CGDisplayBounds(display)
    }

    private func point(_ x: UInt16, _ y: UInt16, in bounds: CGRect) -> CGPoint {
        CGPoint(
            x: bounds.minX + Double(x) / 65535 * (bounds.width - 1),
            y: bounds.minY + Double(y) / 65535 * (bounds.height - 1))
    }

    private func move(to target: CGPoint) {
        let dx = target.x - position.x
        let dy = target.y - position.y
        position = target
        let type: CGEventType
        let held: CGMouseButton
        if buttons.contains(.left) {
            (type, held) = (.leftMouseDragged, .left)
        } else if buttons.contains(.right) {
            (type, held) = (.rightMouseDragged, .right)
        } else if let other = buttons.first {
            (type, held) = (.otherMouseDragged, cgButton(other))
        } else {
            (type, held) = (.mouseMoved, .left)
        }
        guard mode == .inject,
            let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: target, mouseButton: held)
        else { return }
        event.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx.rounded()))
        event.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy.rounded()))
        event.flags = flags(for: nil)
        event.post(tap: .cghidEventTap)
    }

    private func cgButton(_ button: InputMessage.PointerButton) -> CGMouseButton {
        switch button {
        case .left: .left
        case .right: .right
        case .middle: .center
        case .back: CGMouseButton(rawValue: 3)!
        case .forward: CGMouseButton(rawValue: 4)!
        }
    }

    private func button(_ button: InputMessage.PointerButton, down: Bool) {
        if down {
            buttons.insert(button)
            // Consecutive presses of one button, close in time and place, count as a double click.
            let now = ProcessInfo.processInfo.systemUptime
            if let last = lastClick, last.button == button, now - last.time <= NSEvent.doubleClickInterval,
                abs(last.at.x - position.x) <= 4, abs(last.at.y - position.y) <= 4
            {
                lastClick = (button, now, position, last.count + 1)
            } else {
                lastClick = (button, now, position, 1)
            }
        } else if buttons.remove(button) == nil {
            return
        }
        let type: CGEventType
        switch button {
        case .left: type = down ? .leftMouseDown : .leftMouseUp
        case .right: type = down ? .rightMouseDown : .rightMouseUp
        default: type = down ? .otherMouseDown : .otherMouseUp
        }
        guard mode == .inject,
            let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: position, mouseButton: cgButton(button))
        else { return }
        event.setIntegerValueField(.mouseEventClickState, value: Int64(lastClick?.count ?? 1))
        event.flags = flags(for: nil)
        event.post(tap: .cghidEventTap)
    }

    private func scroll(dx: Int16, dy: Int16, units: InputMessage.ScrollUnits) {
        guard mode == .inject else { return }
        let event: CGEvent?
        switch units {
        case .pixels:
            event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0)
            event?.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        case .wheelNotch120:
            // Whole lines, carrying the remainder so that slow wheels still scroll.
            wheelRemainder.x += Int(dx)
            wheelRemainder.y += Int(dy)
            let lines = (x: wheelRemainder.x / 120, y: wheelRemainder.y / 120)
            wheelRemainder.x -= lines.x * 120
            wheelRemainder.y -= lines.y * 120
            guard lines.x != 0 || lines.y != 0 else { return }
            event = CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 2, wheel1: Int32(lines.y), wheel2: Int32(lines.x), wheel3: 0)
        }
        guard let event else { return }
        event.flags = flags(for: nil)
        event.post(tap: .cghidEventTap)
    }
}
