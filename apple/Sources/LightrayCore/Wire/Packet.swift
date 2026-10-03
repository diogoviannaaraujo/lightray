import CryptoKit

/// The 16-byte cleartext header of a protected packet, `docs/packets.md#header`.
public struct ProtectedHeader: Equatable, Sendable {
    public static let length = 16

    public var flags: UInt8
    public var sessionID: UInt32
    public var transportSeq: UInt32
    public var sendTimeMicros: UInt32

    public init(flags: UInt8 = 0, sessionID: UInt32, transportSeq: UInt32, sendTimeMicros: UInt32) {
        self.flags = flags
        self.sessionID = sessionID
        self.transportSeq = transportSeq
        self.sendTimeMicros = sendTimeMicros
    }

    /// Nil for anything that is not a short-form header.
    public init?(_ datagram: Bytes) {
        guard datagram.count >= Self.length, datagram[0] & 0x80 == 0 else { return nil }
        var r = ByteReader(datagram)
        flags = try! r.u8()
        _ = try! r.take(3)
        sessionID = try! r.u32()
        transportSeq = try! r.u32()
        sendTimeMicros = try! r.u32()
    }

    public var bytes: Bytes {
        var w = ByteWriter(capacity: Self.length)
        w.u8(flags)
        w.append([0, 0, 0])
        w.u32(sessionID)
        w.u32(transportSeq)
        w.u32(sendTimeMicros)
        return w.bytes
    }
}

/// One direction's traffic key.
public struct TrafficKey: Sendable {
    let key: SymmetricKey

    public init(_ bytes: Bytes) {
        precondition(bytes.count == 32)
        key = SymmetricKey(data: bytes)
    }
}

public enum Packet {
    public static let tagLength = 16
    /// A header, an empty body and a tag.
    public static let minimumLength = ProtectedHeader.length + tagLength
    /// What a datagram spends beyond its chunks.
    public static let overhead = ProtectedHeader.length + tagLength

    /// `header ‖ AES-256-GCM(chunks)` with the header as associated data and the packet number
    /// as the nonce.
    public static func seal(header: ProtectedHeader, packetNumber: UInt64, key: TrafficKey, chunks: Bytes) -> Bytes {
        precondition(UInt32(truncatingIfNeeded: packetNumber) == header.transportSeq)
        precondition(packetNumber < UInt64.max, "Noise reserves 2^64 - 1")
        let aad = header.bytes
        return aad + Noise.encrypt(key: key.key, nonce: packetNumber, ad: aad, plaintext: chunks)
    }

    /// Opens a datagram whose header has already been parsed. Nil if it does not authenticate.
    public static func open(_ datagram: Bytes, packetNumber: UInt64, key: TrafficKey) -> Bytes? {
        guard datagram.count >= minimumLength else { return nil }
        return Noise.decrypt(
            key: key.key, nonce: packetNumber, ad: Array(datagram[0..<ProtectedHeader.length]),
            ciphertext: datagram[ProtectedHeader.length...])
    }

    /// The 64-bit packet number congruent to `transportSeq` modulo 2³² nearest to `expected`,
    /// taking the larger on a tie, `docs/packets.md#packet-numbers`.
    public static func reconstruct(expected: UInt64, transportSeq: UInt32) -> UInt64 {
        let window: UInt64 = 1 << 32
        let half: UInt64 = 1 << 31
        let candidate = (expected & ~(window - 1)) | UInt64(transportSeq)
        if expected >= candidate, expected - candidate >= half, candidate < UInt64.max - window + 1 {
            return candidate + window
        }
        if candidate > expected, candidate - expected > half, candidate >= window {
            return candidate - window
        }
        return candidate
    }
}

/// The 2048-packet replay window, `docs/packets.md#replay-window`. Checking and recording are
/// separate so that nothing is recorded before a packet authenticates.
public struct ReplayWindow: Sendable {
    public static let size: UInt64 = 2048
    private var bits = [UInt64](repeating: 0, count: Int(ReplayWindow.size / 64))
    public private(set) var highest: UInt64?

    public init() {}

    /// One greater than the highest packet number recorded, and 0 before any.
    public var expected: UInt64 { highest.map { $0 + 1 } ?? 0 }

    public func accepts(_ n: UInt64) -> Bool {
        guard let highest, n <= highest else { return true }
        if highest - n >= Self.size { return false }
        return !bit(n)
    }

    public mutating func record(_ n: UInt64) {
        if let highest {
            if n > highest {
                if n - highest >= Self.size {
                    bits = [UInt64](repeating: 0, count: bits.count)
                } else {
                    var i = highest + 1
                    while i < n {
                        clear(i)
                        i += 1
                    }
                }
                self.highest = n
            }
        } else {
            self.highest = n
        }
        set(n)
    }

    private func bit(_ n: UInt64) -> Bool {
        let i = n % Self.size
        return bits[Int(i / 64)] & (1 << (i % 64)) != 0
    }

    private mutating func set(_ n: UInt64) {
        let i = n % Self.size
        bits[Int(i / 64)] |= 1 << (i % 64)
    }

    private mutating func clear(_ n: UInt64) {
        let i = n % Self.size
        bits[Int(i / 64)] &= ~(1 << (i % 64))
    }
}

/// Wrapping 32-bit microsecond differences, interpreted as signed, `docs/packets.md#clocks`.
@inline(__always)
public func wrappingDifference(_ a: UInt32, _ b: UInt32) -> Int64 { Int64(Int32(bitPattern: a &- b)) }

/// Serial-number comparison for `u32` identifiers: `a` is newer than `b`.
@inline(__always)
public func serialNewer(_ a: UInt32, than b: UInt32) -> Bool { a != b && (a &- b) < (1 << 31) }
