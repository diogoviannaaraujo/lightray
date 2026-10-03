/// Keyboard and pointer messages. **Provisional**: `docs/input.md` leaves input payloads to the
/// application until it is rewritten for version 1, so this format belongs to this
/// implementation, not to the protocol. It follows what version 1 has decided: keys as USB HID
/// usages, the pointer as a position normalised to one of the host's displays, which it names
/// (`docs/displays.md`). See `macos/README.md`.
///
/// Each message is one `RELIABLE` message; its first byte is the type.
public enum InputMessage: Equatable, Sendable {
    /// A key, as a usage on HID page 0x07. `isRepeat` marks the client's autorepeat.
    case key(usage: UInt16, down: Bool, isRepeat: Bool)
    /// The pointer's position on one of the host's displays: 0 is its left or top edge, 65535 its
    /// right or bottom. `display` is the host's `display_id`; 0, or absent from an older client,
    /// means the host's primary display.
    case pointer(x: UInt16, y: UInt16, display: UInt32)
    case button(PointerButton, down: Bool)
    /// Positive `dy` scrolls up and positive `dx` left, as a Mac reports it after applying its own
    /// natural-scrolling setting; the host posts it unchanged.
    case scroll(dx: Int16, dy: Int16, units: ScrollUnits)

    public enum PointerButton: UInt8, Sendable, CaseIterable { case left = 1, right = 2, middle = 3, back = 4, forward = 5 }
    public enum ScrollUnits: UInt8, Sendable { case wheelNotch120 = 0, pixels = 1 }

    public enum Device: Sendable { case keyboard, pointer }

    enum MessageType {
        static let key: UInt8 = 0x01
        static let pointer: UInt8 = 0x10
        static let button: UInt8 = 0x11
        static let scroll: UInt8 = 0x12
    }

    public var device: Device {
        if case .key = self { return .keyboard }
        return .pointer
    }

    public var encoded: Bytes {
        var w = ByteWriter(capacity: 8)
        switch self {
        case .key(let usage, let down, let isRepeat):
            w.u8(MessageType.key)
            w.u16(usage)
            w.u8((down ? 1 : 0) | (isRepeat ? 2 : 0))
        case .pointer(let x, let y, let display):
            w.u8(MessageType.pointer)
            w.u16(x)
            w.u16(y)
            w.u32(display)
        case .button(let button, let down):
            w.u8(MessageType.button)
            w.u8(button.rawValue)
            w.u8(down ? 1 : 0)
        case .scroll(let dx, let dy, let units):
            w.u8(MessageType.scroll)
            w.i16(dx)
            w.i16(dy)
            w.u8(units.rawValue)
        }
        return w.bytes
    }

    /// Nil for an unknown type or a short body. Bytes after the fields are ignored, so fields can
    /// be added at the end.
    public init?(_ bytes: Bytes) {
        var r = ByteReader(bytes)
        guard let type = try? r.u8() else { return nil }
        switch type {
        case MessageType.key:
            guard let usage = try? r.u16(), let flags = try? r.u8() else { return nil }
            self = .key(usage: usage, down: flags & 1 != 0, isRepeat: flags & 2 != 0)
        case MessageType.pointer:
            guard let x = try? r.u16(), let y = try? r.u16() else { return nil }
            self = .pointer(x: x, y: y, display: (try? r.u32()) ?? 0)
        case MessageType.button:
            guard let b = try? r.u8(), let button = PointerButton(rawValue: b), let down = try? r.u8() else { return nil }
            self = .button(button, down: down != 0)
        case MessageType.scroll:
            guard let dx = try? r.i16(), let dy = try? r.i16(), let u = try? r.u8(), let units = ScrollUnits(rawValue: u)
            else { return nil }
            self = .scroll(dx: dx, dy: dy, units: units)
        default:
            return nil
        }
    }
}
