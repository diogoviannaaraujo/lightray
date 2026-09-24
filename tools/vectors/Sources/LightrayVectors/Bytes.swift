public typealias Bytes = [UInt8]

extension Array where Element == UInt8 {
    /// Parses hex, ignoring whitespace. Traps on anything else: every input is a constant.
    public init(hex: String) {
        let digits = hex.filter { !$0.isWhitespace }
        precondition(digits.count % 2 == 0, "odd number of hex digits")
        var bytes = Bytes()
        bytes.reserveCapacity(digits.count / 2)
        var index = digits.startIndex
        while index < digits.endIndex {
            let next = digits.index(index, offsetBy: 2)
            guard let byte = UInt8(digits[index..<next], radix: 16) else {
                preconditionFailure("invalid hex: \(digits[index..<next])")
            }
            bytes.append(byte)
            index = next
        }
        self = bytes
    }

    public var hex: String {
        let digits = [Character]("0123456789abcdef")
        var out = ""
        out.reserveCapacity(count * 2)
        for byte in self {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0f)])
        }
        return out
    }
}

public func be16(_ value: UInt16) -> Bytes { [UInt8(value >> 8), UInt8(value & 0xff)] }

public func be32(_ value: UInt32) -> Bytes {
    (0..<4).reversed().map { UInt8((value >> (8 * UInt32($0))) & 0xff) }
}

public func be64(_ value: UInt64) -> Bytes {
    (0..<8).reversed().map { UInt8((value >> (8 * UInt64($0))) & 0xff) }
}

public func readBE(_ bytes: some Collection<UInt8>) -> UInt64 {
    bytes.reduce(0) { ($0 << 8) | UInt64($1) }
}

/// Hex at `perLine` bytes a line, the layout every multi-line example in `docs/` uses.
public func hexLines(_ bytes: Bytes, perLine: Int = 16) -> String {
    stride(from: 0, to: bytes.count, by: perLine)
        .map { Array(bytes[$0..<Swift.min($0 + perLine, bytes.count)]).hex }
        .joined(separator: "\n")
}

/// `0x`-prefixed hex of a fixed width, for tables of integers.
public func hexNumber(_ value: UInt64, digits: Int) -> String {
    let raw = String(value, radix: 16)
    return "0x" + String(repeating: "0", count: Swift.max(0, digits - raw.count)) + raw
}
