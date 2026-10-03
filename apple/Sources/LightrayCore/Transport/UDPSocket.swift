import Darwin
import Dispatch

/// The monotonic clock every timestamp is drawn from, in microseconds. `CLOCK_UPTIME_RAW` is the
/// clock ScreenCaptureKit and VideoToolbox stamp samples with, so capture times need no conversion.
public func monotonicMicros() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1000 }

public func unixSeconds() -> UInt64 { UInt64(time(nil)) }

public struct SocketError: Error, CustomStringConvertible {
    public let description: String
    init(_ what: String) { description = "\(what): \(String(cString: strerror(errno)))" }
    init(message: String) { description = message }
}

/// A non-blocking UDP socket read on a dispatch queue. It sets don't-fragment, so a datagram the
/// path cannot carry fails instead of being fragmented, and marks its traffic as interactive video.
public final class UDPSocket: @unchecked Sendable {
    public let fd: Int32
    private let family: Int32
    private let queue: DispatchQueue
    private var source: DispatchSourceRead?
    private var buffer = [UInt8](repeating: 0, count: 65536)
    /// For testing repair on a clean network: the fraction of arriving datagrams to drop.
    public var dropRate = 0.0
    public private(set) var sendFailures = 0
    public private(set) var dropped = 0

    /// A socket for `family` (`AF_INET` or `AF_INET6`), bound to `port` (0 for any). An `AF_INET6`
    /// socket also accepts IPv4.
    public init(family: Int32 = AF_INET6, port: UInt16 = 0, queue: DispatchQueue) throws {
        self.family = family
        self.queue = queue
        fd = socket(family, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw SocketError("socket") }
        var on: Int32 = 1
        var off: Int32 = 0
        var bufferSize: Int32 = 4 << 20
        var service: Int32 = 3  // NET_SERVICE_TYPE_VI
        let size = socklen_t(MemoryLayout<Int32>.size)
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &bufferSize, size)
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &bufferSize, size)
        setsockopt(fd, SOL_SOCKET, SO_NET_SERVICE_TYPE, &service, size)
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, size)
        if family == AF_INET6 {
            setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &off, size)
            setsockopt(fd, IPPROTO_IPV6, 62 /* IPV6_DONTFRAG, hidden behind __APPLE_USE_RFC_3542 */, &on, size)
        }
        // On a dual-stack socket this may be refused; IPv4 traffic then goes without it.
        setsockopt(fd, IPPROTO_IP, IP_DONTFRAG, &on, size)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        var status: Int32
        if family == AF_INET6 {
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = port.bigEndian
            address.sin6_addr = in6addr_any
            status = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
            }
        } else {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            status = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        }
        guard status == 0 else {
            let error = SocketError("bind to port \(port)")
            Darwin.close(fd)
            throw error
        }
    }

    public var localPort: UInt16 {
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        _ = withUnsafeMutablePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        return Self.peer(from: storage).port
    }

    /// Starts reading; `handler` runs on the socket's queue for every datagram.
    public func start(_ handler: @escaping (Bytes, PeerAddress) -> Void) {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [unowned self] in
            while true {
                var storage = sockaddr_storage()
                var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
                let count = buffer.withUnsafeMutableBytes { bytes in
                    withUnsafeMutablePointer(to: &storage) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            recvfrom(fd, bytes.baseAddress, bytes.count, 0, $0, &length)
                        }
                    }
                }
                guard count >= 0 else { break }  // EAGAIN: drained.
                if dropRate > 0, Double.random(in: 0..<1) < dropRate {
                    dropped += 1
                    continue
                }
                handler(Array(buffer[0..<count]), Self.peer(from: storage))
            }
        }
        source.resume()
        self.source = source
    }

    public func send(_ datagram: Bytes, to peer: PeerAddress) {
        var storage = Self.socketAddress(for: peer, family: family)
        let length = socklen_t(storage.ss_len)
        let sent = datagram.withUnsafeBytes { bytes in
            withUnsafePointer(to: &storage) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, bytes.baseAddress, bytes.count, 0, $0, length) }
            }
        }
        if sent < 0 { sendFailures += 1 }
    }

    public func close() {
        source?.cancel()
        source = nil
        Darwin.close(fd)
    }

    // MARK: Addresses

    static func peer(from storage: sockaddr_storage) -> PeerAddress {
        var storage = storage
        if Int32(storage.ss_family) == AF_INET {
            return withUnsafePointer(to: &storage) {
                $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { a in
                    let ip = withUnsafeBytes(of: a.pointee.sin_addr) { Bytes($0) }
                    return PeerAddress(ip: ip, port: UInt16(bigEndian: a.pointee.sin_port))
                }
            }
        }
        return withUnsafePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { a in
                var ip = withUnsafeBytes(of: a.pointee.sin6_addr) { Bytes($0) }
                // IPv4 through a dual-stack socket arrives mapped: ::ffff:a.b.c.d.
                if ip.prefix(12) == [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff] { ip = Array(ip.suffix(4)) }
                return PeerAddress(ip: ip, port: UInt16(bigEndian: a.pointee.sin6_port))
            }
        }
    }

    static func socketAddress(for peer: PeerAddress, family: Int32) -> sockaddr_storage {
        var storage = sockaddr_storage()
        if family == AF_INET {
            withUnsafeMutablePointer(to: &storage) {
                $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { a in
                    a.pointee.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                    a.pointee.sin_family = sa_family_t(AF_INET)
                    a.pointee.sin_port = peer.port.bigEndian
                    withUnsafeMutableBytes(of: &a.pointee.sin_addr) { $0.copyBytes(from: peer.ip.prefix(4)) }
                }
            }
        } else {
            let ip = peer.ip.count == 4 ? [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff] + peer.ip : peer.ip
            withUnsafeMutablePointer(to: &storage) {
                $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { a in
                    a.pointee.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
                    a.pointee.sin6_family = sa_family_t(AF_INET6)
                    a.pointee.sin6_port = peer.port.bigEndian
                    withUnsafeMutableBytes(of: &a.pointee.sin6_addr) { $0.copyBytes(from: ip) }
                }
            }
        }
        return storage
    }

    /// Resolves `host` (a name or a literal address) and `port`, preferring IPv4. Returns the
    /// address and the socket family to reach it with.
    public static func resolve(_ host: String, port: UInt16) throws -> (PeerAddress, Int32) {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_DGRAM
        hints.ai_protocol = IPPROTO_UDP
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, String(port), &hints, &result)
        guard status == 0, let first = result else {
            throw SocketError(message: "cannot resolve \(host): \(String(cString: gai_strerror(status)))")
        }
        defer { freeaddrinfo(result) }
        var candidates: [(PeerAddress, Int32)] = []
        var node: UnsafeMutablePointer<addrinfo>? = first
        while let info = node {
            var storage = sockaddr_storage()
            withUnsafeMutableBytes(of: &storage) { dst in
                dst.copyMemory(from: UnsafeRawBufferPointer(start: info.pointee.ai_addr, count: Int(info.pointee.ai_addrlen)))
            }
            candidates.append((peer(from: storage), info.pointee.ai_family))
            node = info.pointee.ai_next
        }
        return candidates.first { $0.1 == AF_INET } ?? candidates[0]
    }
}
