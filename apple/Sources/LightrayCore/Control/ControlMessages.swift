/// One of the host's displays, as `docs/displays.md` describes it.
public struct DisplayInfo: Equatable, Sendable {
    public var id: UInt32
    public var isPrimary: Bool
    public var supportsHDR: Bool
    /// The current mode, in pixels.
    public var width: Int
    public var height: Int
    public var refreshMillihertz: UInt32
    /// Where the display sits in the host's desktop, in the host's desktop coordinates.
    public var layoutX: Int32
    public var layoutY: Int32
    public var layoutWidth: UInt32
    public var layoutHeight: UInt32
    public var name: String

    public init(
        id: UInt32, isPrimary: Bool, supportsHDR: Bool = false, width: Int, height: Int, refreshMillihertz: UInt32,
        layoutX: Int32, layoutY: Int32, layoutWidth: UInt32, layoutHeight: UInt32, name: String
    ) {
        self.id = id
        self.isPrimary = isPrimary
        self.supportsHDR = supportsHDR
        self.width = width
        self.height = height
        self.refreshMillihertz = refreshMillihertz
        self.layoutX = layoutX
        self.layoutY = layoutY
        self.layoutWidth = layoutWidth
        self.layoutHeight = layoutHeight
        self.name = name
    }

    static let maxNameBytes = 64

    var encoded: Bytes {
        var w = ByteWriter(capacity: 32 + Self.maxNameBytes)
        w.u32(id)
        w.u8((isPrimary ? 1 : 0) | (supportsHDR ? 2 : 0))
        w.u16(UInt16(clamping: width))
        w.u16(UInt16(clamping: height))
        w.u32(refreshMillihertz)
        w.u32(UInt32(bitPattern: layoutX))
        w.u32(UInt32(bitPattern: layoutY))
        w.u32(layoutWidth)
        w.u32(layoutHeight)
        // At most 64 bytes, cut at a character boundary.
        var name = Bytes()
        for character in self.name {
            let bytes = Bytes(String(character).utf8)
            guard name.count + bytes.count <= Self.maxNameBytes else { break }
            name += bytes
        }
        w.append(name)
        return w.bytes
    }

    static func parse(_ value: ArraySlice<UInt8>) -> DisplayInfo? {
        var r = ByteReader(value)
        guard let id = try? r.u32(), id != 0, let flags = try? r.u8(), let width = try? r.u16(),
            let height = try? r.u16(), let refresh = try? r.u32(), let x = try? r.u32(), let y = try? r.u32(),
            let layoutWidth = try? r.u32(), let layoutHeight = try? r.u32()
        else { return nil }
        let name = r.rest()
        let text = String(decoding: name, as: UTF8.self)
        guard name.count <= maxNameBytes, Array(text.utf8) == Array(name) else { return nil }
        return DisplayInfo(
            id: id, isPrimary: flags & 1 != 0, supportsHDR: flags & 2 != 0, width: Int(width), height: Int(height),
            refreshMillihertz: refresh, layoutX: Int32(bitPattern: x), layoutY: Int32(bitPattern: y),
            layoutWidth: layoutWidth, layoutHeight: layoutHeight, name: text)
    }
}

/// Control messages on stream 0 for choosing displays. **Provisional**: they use the message shape
/// of `docs/control.md`'s version 0 text (`msg_type, req_id, scope_stream, TLVs`) with numbers from
/// 0xF0 up for what that text does not define. `docs/displays.md` defines what they mean; their
/// real numbers come when control.md is rewritten. See `macos/README.md`.
public enum ControlMessage: Equatable, Sendable {
    /// Client to host: show `display` on video stream `stream`, 0 for nothing.
    case selectDisplay(reqID: UInt32, stream: UInt8, display: UInt32)
    /// Host to client: the answer to one `selectDisplay`, with the display the stream now shows.
    case displaySelected(reqID: UInt32, stream: UInt8, display: UInt32)
    /// Host to client, unsolicited: the display a stream shows, 0 for none.
    case streamDisplay(stream: UInt8, display: UInt32)
    /// Host to client: every display the host can stream.
    case displays([DisplayInfo])

    enum MessageType {
        static let reconfigure: UInt8 = 1
        static let reconfigureResult: UInt8 = 2
        static let state: UInt8 = 3
        static let displays: UInt8 = 0xF0
    }

    enum TLV {
        static let display: UInt8 = 0xF0
        static let displayInfo: UInt8 = 0xF1
    }

    public var encoded: Bytes {
        var w = ByteWriter()
        func header(_ type: UInt8, _ reqID: UInt32, _ stream: UInt8) {
            w.u8(type)
            w.u32(reqID)
            w.u8(stream)
        }
        func display(_ id: UInt32) {
            var v = ByteWriter()
            v.u32(id)
            w.tlv(TLV.display, v.bytes)
        }
        switch self {
        case .selectDisplay(let reqID, let stream, let id):
            header(MessageType.reconfigure, reqID, stream)
            display(id)
        case .displaySelected(let reqID, let stream, let id):
            header(MessageType.reconfigureResult, reqID, stream)
            display(id)
        case .streamDisplay(let stream, let id):
            header(MessageType.state, 0, stream)
            display(id)
        case .displays(let list):
            header(MessageType.displays, 0, 0)
            for info in list { w.tlv(TLV.displayInfo, info.encoded) }
        }
        return w.bytes
    }

    /// Nil for a message this implementation does not handle, or one whose TLVs do not exactly
    /// consume it. Unknown TLVs are skipped.
    public init?(_ bytes: Bytes) {
        var r = ByteReader(bytes)
        guard let type = try? r.u8(), let reqID = try? r.u32(), let stream = try? r.u8() else { return nil }
        var display: UInt32?
        var infos: [DisplayInfo] = []
        while !r.isAtEnd {
            guard let t = try? r.u8(), let length = try? r.u16(), let value = try? r.take(Int(length)) else { return nil }
            switch t {
            case TLV.display:
                var v = ByteReader(value)
                guard length == 4 else { return nil }
                display = try! v.u32()
            case TLV.displayInfo:
                guard let info = DisplayInfo.parse(value) else { return nil }
                infos.append(info)
            default:
                break
            }
        }
        switch type {
        case MessageType.reconfigure:
            guard let display else { return nil }
            self = .selectDisplay(reqID: reqID, stream: stream, display: display)
        case MessageType.reconfigureResult:
            guard let display else { return nil }
            self = .displaySelected(reqID: reqID, stream: stream, display: display)
        case MessageType.state:
            guard let display else { return nil }
            self = .streamDisplay(stream: stream, display: display)
        case MessageType.displays:
            self = .displays(infos)
        default:
            return nil
        }
    }
}
