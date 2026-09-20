import Darwin
import LightraySession

public struct SocketError: Error, CustomStringConvertible {
    public let operation: String
    public let code: Int32
    public var description: String { "\(operation): \(String(cString: strerror(code))) (\(code))" }
}
public struct SuspendingClock: MonotonicClock, Sendable {
    public init() {}
    public func now() -> Instant { .init(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) }
}
public final class UDPSocket {
    public let descriptor: Int32
    public let localPort: UInt16
    public let receiveBufferSize: Int32
    public let sendBufferSize: Int32
    public init(port: UInt16 = 0) throws {
        let fd = socket(AF_INET6, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw SocketError(operation: "socket", code: errno) }
        do {
            func option(_ level: Int32, _ name: Int32, _ value: Int32) throws {
                var value = value
                guard setsockopt(fd, level, name, &value, socklen_t(MemoryLayout<Int32>.size)) == 0 else { throw SocketError(operation: "setsockopt \(name)", code: errno) }
            }
            try option(IPPROTO_IPV6, IPV6_V6ONLY, 0)
            try option(IPPROTO_IPV6, 62, 1)
            try option(SOL_SOCKET, SO_RCVBUF, 8 * 1024 * 1024)
            try option(SOL_SOCKET, SO_SNDBUF, 8 * 1024 * 1024)
            try option(SOL_SOCKET, SO_NET_SERVICE_TYPE, NET_SERVICE_TYPE_VI)
            guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw SocketError(operation: "fcntl", code: errno) }
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = port.bigEndian
            let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } }
            guard bound == 0 else { throw SocketError(operation: "bind", code: errno) }
            var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
            let named = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
            guard named == 0 else { throw SocketError(operation: "getsockname", code: errno) }
            var receive: Int32 = 0
            var send: Int32 = 0
            length = 4
            guard getsockopt(fd, SOL_SOCKET, SO_RCVBUF, &receive, &length) == 0, getsockopt(fd, SOL_SOCKET, SO_SNDBUF, &send, &length) == 0 else { throw SocketError(operation: "getsockopt", code: errno) }
            descriptor = fd
            localPort = UInt16(bigEndian: address.sin6_port)
            receiveBufferSize = receive
            sendBufferSize = send
        } catch {
            Darwin.close(fd)
            throw error
        }
    }
    deinit { Darwin.close(descriptor) }
    public func send(_ bytes: [UInt8], to peer: PeerAddress) throws -> Bool {
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = peer.port.bigEndian
        let host = peer.host.contains(":") ? peer.host : "::ffff:\(peer.host)"
        guard host.withCString({ inet_pton(AF_INET6, $0, &address.sin6_addr) }) == 1 else { throw SocketError(operation: "numeric peer address required", code: EINVAL) }
        let count = bytes.withUnsafeBytes { bytes in withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(descriptor, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } } }
        if count < 0 {
            if errno == EAGAIN || errno == ENOBUFS { return false }
            throw SocketError(operation: "sendto", code: errno)
        }
        return count == bytes.count
    }
    public func receive(into buffer: UnsafeMutableRawBufferPointer) throws -> (count: Int, peer: PeerAddress)? {
        var address = sockaddr_in6()
        var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        let count = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(descriptor, buffer.baseAddress, buffer.count, 0, $0, &length) } }
        if count < 0 {
            if errno == EAGAIN || errno == EWOULDBLOCK { return nil }
            throw SocketError(operation: "recvfrom", code: errno)
        }
        var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &address.sin6_addr, &text, socklen_t(text.count)) != nil else { throw SocketError(operation: "inet_ntop", code: errno) }
        let host = String(decoding: text.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return (count, .init(host: host, port: UInt16(bigEndian: address.sin6_port)))
    }
}
