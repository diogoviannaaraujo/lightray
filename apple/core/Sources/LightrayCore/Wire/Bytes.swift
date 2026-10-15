public typealias Bytes = [UInt8]

/// A byte string ended before a field it declared, or declared something impossible.
public struct WireError: Error, Equatable, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }

    public static let truncated = WireError("truncated")
}

/// Appends big-endian integers and byte strings.
public struct ByteWriter {
    public private(set) var bytes: Bytes

    public init(capacity: Int = 64) {
        bytes = []
        bytes.reserveCapacity(capacity)
    }

    public var count: Int { bytes.count }

    public mutating func u8(_ value: UInt8) { bytes.append(value) }

    public mutating func u16(_ value: UInt16) {
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
        bytes.append(UInt8(truncatingIfNeeded: value))
    }

    public mutating func i16(_ value: Int16) { u16(UInt16(bitPattern: value)) }

    public mutating func u32(_ value: UInt32) {
        bytes.append(UInt8(truncatingIfNeeded: value >> 24))
        bytes.append(UInt8(truncatingIfNeeded: value >> 16))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
        bytes.append(UInt8(truncatingIfNeeded: value))
    }

    public mutating func u64(_ value: UInt64) {
        u32(UInt32(truncatingIfNeeded: value >> 32))
        u32(UInt32(truncatingIfNeeded: value))
    }

    public mutating func append<C: Collection>(_ other: C) where C.Element == UInt8 { bytes.append(contentsOf: other) }

    /// Writes `type:u8, length:u16, value`, the shape of every chunk and TLV.
    public mutating func tlv<C: Collection>(_ type: UInt8, _ value: C) where C.Element == UInt8 {
        precondition(value.count <= Int(UInt16.max))
        u8(type)
        u16(UInt16(value.count))
        append(value)
    }

    /// Overwrites a `u16` already written, for lengths known only once the body is built.
    public mutating func patchU16(at offset: Int, _ value: UInt16) {
        bytes[offset] = UInt8(truncatingIfNeeded: value >> 8)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value)
    }
}

/// Reads big-endian integers from a byte string, failing instead of trapping at its end.
public struct ByteReader {
    public let bytes: ArraySlice<UInt8>
    public private(set) var offset: Int

    public init(_ bytes: Bytes) { self.init(bytes[...]) }

    public init(_ bytes: ArraySlice<UInt8>) {
        self.bytes = bytes
        offset = bytes.startIndex
    }

    public var remaining: Int { bytes.endIndex - offset }
    public var isAtEnd: Bool { offset >= bytes.endIndex }

    public mutating func u8() throws(WireError) -> UInt8 {
        guard remaining >= 1 else { throw .truncated }
        defer { offset += 1 }
        return bytes[offset]
    }

    public mutating func u16() throws(WireError) -> UInt16 {
        guard remaining >= 2 else { throw .truncated }
        defer { offset += 2 }
        return UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }

    public mutating func i16() throws(WireError) -> Int16 { Int16(bitPattern: try u16()) }

    public mutating func u32() throws(WireError) -> UInt32 {
        guard remaining >= 4 else { throw .truncated }
        defer { offset += 4 }
        return UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }

    public mutating func u64() throws(WireError) -> UInt64 {
        let high = try u32()
        return UInt64(high) << 32 | UInt64(try u32())
    }

    public mutating func take(_ count: Int) throws(WireError) -> ArraySlice<UInt8> {
        guard count >= 0, remaining >= count else { throw .truncated }
        defer { offset += count }
        return bytes[offset..<offset + count]
    }

    public mutating func rest() -> ArraySlice<UInt8> {
        defer { offset = bytes.endIndex }
        return bytes[offset...]
    }
}

extension Array where Element == UInt8 {
    /// Parses hex, ignoring whitespace. Returns nil on anything else.
    public init?(hex: String) {
        let digits = Array(hex.utf8.filter { !($0 == 0x20 || $0 == 0x0a || $0 == 0x0d || $0 == 0x09) })
        guard digits.count % 2 == 0 else { return nil }
        var bytes = Bytes()
        bytes.reserveCapacity(digits.count / 2)
        func nibble(_ c: UInt8) -> UInt8? {
            switch c {
            case 0x30...0x39: c - 0x30
            case 0x61...0x66: c - 0x61 + 10
            case 0x41...0x46: c - 0x41 + 10
            default: nil
            }
        }
        var i = 0
        while i < digits.count {
            guard let high = nibble(digits[i]), let low = nibble(digits[i + 1]) else { return nil }
            bytes.append(high << 4 | low)
            i += 2
        }
        self = bytes
    }

    public var hex: String {
        let digits = Array("0123456789abcdef".utf8)
        var out = [UInt8]()
        out.reserveCapacity(count * 2)
        for byte in self {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0f)])
        }
        return String(decoding: out, as: UTF8.self)
    }
}

/// Compares two byte strings in time that depends only on their lengths.
public func constantTimeEqual(_ a: Bytes, _ b: Bytes) -> Bool {
    guard a.count == b.count else { return false }
    var difference: UInt8 = 0
    for i in 0..<a.count { difference |= a[i] ^ b[i] }
    return difference == 0
}
