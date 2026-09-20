import LightrayCore

/// An opaque peer address, as far as the sans-IO core is concerned: it compares
/// them and hands them back, but never interprets them. The runtime fills one
/// from a `sockaddr_in6` (28 bytes, so 32 is always enough).
public struct PeerAddress: Hashable, Sendable, CustomStringConvertible {
    public static let capacity = 32

    public var w0: UInt64 = 0
    public var w1: UInt64 = 0
    public var w2: UInt64 = 0
    public var w3: UInt64 = 0
    public var length: UInt8 = 0

    public init() {}

    public init(_ raw: UnsafeRawBufferPointer) {
        let n = min(raw.count, Self.capacity)
        length = UInt8(n)
        withUnsafeMutableBytes(of: &self) { dst in
            dst.copyMemory(from: UnsafeRawBufferPointer(rebasing: raw[..<n]))
        }
        length = UInt8(n)
    }

    /// Copies the address bytes out, for the runtime to pass to `sendto`.
    public func withBytes<R>(_ body: (UnsafeRawBufferPointer) -> R) -> R {
        var copy = self
        return withUnsafeBytes(of: &copy) { raw in
            body(UnsafeRawBufferPointer(rebasing: raw[..<Int(length)]))
        }
    }

    /// A synthetic address for tests and the simulated network.
    public static func synthetic(_ id: UInt64, port: UInt16 = 0) -> PeerAddress {
        var a = PeerAddress()
        a.w0 = id
        a.w1 = UInt64(port)
        a.length = 28
        return a
    }

    public var description: String { "peer(\(w0):\(w1))" }
}
