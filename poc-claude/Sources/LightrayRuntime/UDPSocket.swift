import Darwin
import LightrayCore
import LightrayEngine

/// A non-blocking, dual-stack UDP socket.
///
/// Every option here is set the way Phase 0 measured it working, not the way the
/// documentation suggests:
/// - `IPV6_DONTFRAG` (value 62; Swift does not import it, because the header
///   hides it behind `__APPLE_USE_RFC_3542`) works and covers v4-mapped peers.
///   `IP_DONTFRAG` and `IP_TOS` both fail with EINVAL on a dual-stack socket.
/// - `SO_RCVBUF`/`SO_SNDBUF` accept up to about 32 MB but are silently capped at
///   8 MB by `kern.ipc.maxsockbuf`, so there is no point asking for more.
/// - `SO_NET_SERVICE_TYPE` is accepted and read back but writes no DSCP unless
///   `net.qos.policy.*` is on. It is set anyway, because the Wi-Fi driver's WMM
///   category is decided inside the driver.
public final class UDPSocket {
    /// `netinet6/in6.h` defines this only under `__APPLE_USE_RFC_3542`.
    public static let IPV6_DONTFRAG: Int32 = 62
    public static let maxSocketBuffer: Int32 = 8 << 20

    public let fd: Int32

    public enum SocketError: Error, Equatable {
        case create(Int32)
        case bind(Int32)
    }

    public init(port: UInt16 = 0, dontFragment: Bool = true) throws {
        fd = socket(AF_INET6, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw SocketError.create(errno) }

        // Dual stack: a v4 peer arrives as ::ffff:a.b.c.d and sending to a
        // v4-mapped address works, so one socket serves both families.
        var off: Int32 = 0
        setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &off, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        var big = Self.maxSocketBuffer
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &big, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &big, socklen_t(MemoryLayout<Int32>.size))

        if dontFragment {
            // So a padded INIT that is too big for the path fails with EMSGSIZE
            // instead of being fragmented: that is what proves the path MTU.
            var on: Int32 = 1
            setsockopt(fd, IPPROTO_IPV6, Self.IPV6_DONTFRAG, &on, socklen_t(MemoryLayout<Int32>.size))
        }

        // Interactive video: the value is accepted everywhere, and on a
        // QoS-capable Wi-Fi link it selects the WMM video category.
        var service: Int32 = 5   // NET_SERVICE_TYPE_VI
        setsockopt(fd, SOL_SOCKET, SO_NET_SERVICE_TYPE, &service, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = port.bigEndian
        address.sin6_addr = in6addr_any
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        guard bound == 0 else {
            let e = errno
            close(fd)
            throw SocketError.bind(e)
        }
    }

    deinit { close(fd) }

    public func closeSocket() { close(fd) }

    public var localPort: UInt16 {
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        _ = withUnsafeMutablePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        return withUnsafeBytes(of: &storage) {
            UInt16(bigEndian: $0.load(fromByteOffset: 2, as: UInt16.self))
        }
    }

    /// Sends one datagram. Returns bytes sent, or -errno.
    @discardableResult
    public func send(_ bytes: UnsafeRawBufferPointer, to peer: PeerAddress) -> Int {
        peer.withBytes { raw in
            raw.withMemoryRebound(to: sockaddr.self) { sa in
                let n = sendto(fd, bytes.baseAddress, bytes.count, 0, sa.baseAddress, socklen_t(raw.count))
                return n < 0 ? -Int(errno) : n
            }
        }
    }

    /// Receives one datagram, or nil when the socket is drained.
    public func receive(into buffer: UnsafeMutableRawBufferPointer) -> (length: Int, from: PeerAddress)? {
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let n = withUnsafeMutablePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                recvfrom(fd, buffer.baseAddress, buffer.count, 0, $0, &length)
            }
        }
        guard n > 0 else { return nil }
        let peer = withUnsafeBytes(of: &storage) { raw in
            PeerAddress(UnsafeRawBufferPointer(rebasing: raw[..<Int(length)]))
        }
        return (n, peer)
    }

    /// `SO_ERROR`, which is how a socket that went defunct while the process was
    /// suspended announces itself.
    public var pendingError: Int32 {
        var value: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &value, &length) == 0 else { return errno }
        return value
    }

    /// An IPv6 or v4-mapped destination. An IPv4 literal becomes ::ffff:a.b.c.d.
    public static func address(host: String, port: UInt16) -> PeerAddress? {
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = port.bigEndian
        let literal = host.contains(":") ? host : "::ffff:" + host
        guard inet_pton(AF_INET6, literal, &address.sin6_addr) == 1 else { return nil }
        return withUnsafeBytes(of: &address) {
            PeerAddress(UnsafeRawBufferPointer(rebasing: $0[..<MemoryLayout<sockaddr_in6>.size]))
        }
    }

    public static func loopback(port: UInt16) -> PeerAddress {
        address(host: "127.0.0.1", port: port)!
    }
}
