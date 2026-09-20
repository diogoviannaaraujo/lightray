import Darwin
import Foundation
import Synchronization

// Darwin socket suppositions: dual-stack, ephemeral port on re-create, buffer caps,
// SO_NET_SERVICE_TYPE → DSCP, IP(V6)_DONTFRAG, EVFILT_READ wake latency.

// MARK: - Helpers

/// netinet6/in6.h defines this only under __APPLE_USE_RFC_3542, so the Darwin module does not import it.
let IPV6_DONTFRAG: Int32 = 62

func udp6() -> Int32 {
    let fd = socket(AF_INET6, SOCK_DGRAM, IPPROTO_UDP)
    var off: Int32 = 0
    setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &off, socklen_t(MemoryLayout<Int32>.size))
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    return fd
}

func udp4() -> Int32 {
    let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    return fd
}

func bind6(_ fd: Int32, port: UInt16 = 0) -> Bool {
    var a = sockaddr_in6()
    a.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
    a.sin6_family = sa_family_t(AF_INET6)
    a.sin6_port = port.bigEndian
    a.sin6_addr = in6addr_any
    return withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } } == 0
}

func bind4(_ fd: Int32, port: UInt16 = 0) -> Bool {
    var a = sockaddr_in()
    a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    a.sin_family = sa_family_t(AF_INET)
    a.sin_port = port.bigEndian
    a.sin_addr.s_addr = INADDR_ANY
    return withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } == 0
}

func localPort(_ fd: Int32) -> UInt16 {
    var ss = sockaddr_storage()
    var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
    _ = withUnsafeMutablePointer(to: &ss) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
    return withUnsafeBytes(of: &ss) { UInt16(bigEndian: $0.load(fromByteOffset: 2, as: UInt16.self)) }
}

/// IPv6 destination; IPv4 literals become ::ffff:a.b.c.d (v4-mapped) for dual-stack sockets.
func addr6(_ host: String, _ port: UInt16) -> sockaddr_in6 {
    var a = sockaddr_in6()
    a.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
    a.sin6_family = sa_family_t(AF_INET6)
    a.sin6_port = port.bigEndian
    let literal = host.contains(":") ? host : "::ffff:" + host
    precondition(inet_pton(AF_INET6, literal, &a.sin6_addr) == 1)
    return a
}

func addr4(_ host: String, _ port: UInt16) -> sockaddr_in {
    var a = sockaddr_in()
    a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    a.sin_family = sa_family_t(AF_INET)
    a.sin_port = port.bigEndian
    precondition(inet_pton(AF_INET, host, &a.sin_addr) == 1)
    return a
}

func send(_ fd: Int32, _ buf: UnsafeRawBufferPointer, to a: sockaddr_in6) -> Int {
    var a = a
    return withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        sendto(fd, buf.baseAddress, buf.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
    } }
}

func send(_ fd: Int32, _ buf: UnsafeRawBufferPointer, to a: sockaddr_in) -> Int {
    var a = a
    return withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        sendto(fd, buf.baseAddress, buf.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
    } }
}

func setInt(_ fd: Int32, _ level: Int32, _ name: Int32, _ v: Int32) -> Int32 {
    var v = v
    return setsockopt(fd, level, name, &v, socklen_t(MemoryLayout<Int32>.size)) == 0 ? 0 : errno
}

func getInt(_ fd: Int32, _ level: Int32, _ name: Int32) -> Int32 {
    var v: Int32 = -1
    var len = socklen_t(MemoryLayout<Int32>.size)
    return getsockopt(fd, level, name, &v, &len) == 0 ? v : -errno
}

func waitReadable(_ fd: Int32, ms: Int32) -> Bool {
    var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    return poll(&p, 1, ms) == 1
}

struct Received { var n: Int; var tos: Int?; var tclass: Int?; var fromFamily: Int32; var fromMapped: Bool }

/// recvmsg with ancillary data (IP_RECVTOS / IPV6_TCLASS).
func receive(_ fd: Int32, into buf: UnsafeMutableRawBufferPointer) -> Received? {
    var from = sockaddr_storage()
    var iov = iovec(iov_base: buf.baseAddress, iov_len: buf.count)
    let ctrl = UnsafeMutableRawBufferPointer.allocate(byteCount: 256, alignment: 8)
    defer { ctrl.deallocate() }
    var msg = msghdr()
    let n = withUnsafeMutablePointer(to: &from) { fromPtr in
        withUnsafeMutablePointer(to: &iov) { iovPtr in
            msg.msg_name = UnsafeMutableRawPointer(fromPtr)
            msg.msg_namelen = socklen_t(MemoryLayout<sockaddr_storage>.size)
            msg.msg_iov = iovPtr
            msg.msg_iovlen = 1
            msg.msg_control = ctrl.baseAddress
            msg.msg_controllen = socklen_t(ctrl.count)
            return recvmsg(fd, &msg, 0)
        }
    }
    guard n >= 0 else { return nil }
    var r = Received(n: n, tos: nil, tclass: nil, fromFamily: Int32(from.ss_family), fromMapped: false)
    if r.fromFamily == AF_INET6 {
        r.fromMapped = withUnsafeBytes(of: &from) { b in
            (8..<18).allSatisfy { b[$0] == 0 } && b[18] == 0xFF && b[19] == 0xFF
        }
    }
    let align = { (x: Int) in (x + 3) & ~3 }
    var off = 0
    let hdr = MemoryLayout<cmsghdr>.size
    while off + hdr <= Int(msg.msg_controllen) {
        let h = ctrl.load(fromByteOffset: off, as: cmsghdr.self)
        guard h.cmsg_len >= hdr else { break }
        let data = off + align(hdr)
        if h.cmsg_level == IPPROTO_IP && (h.cmsg_type == IP_RECVTOS || h.cmsg_type == IP_TOS) { r.tos = Int(ctrl[data]) }
        if h.cmsg_level == IPPROTO_IPV6 && h.cmsg_type == IPV6_TCLASS { r.tclass = Int(ctrl.loadUnaligned(fromByteOffset: data, as: Int32.self)) }
        off += align(Int(h.cmsg_len))
    }
    return r
}

func fmtMB(_ b: Int32) -> String { String(format: "%.2f MB", Double(b) / 1_048_576) }

// MARK: - Probe

public func socketProbe(quick: Bool = false, allowExternalProbe: Bool = true) -> Report {
    var rep = Report("Sockets — Darwin UDP suppositions")
    let buf = UnsafeMutableRawBufferPointer.allocate(byteCount: 65536, alignment: 16)
    buf.initializeMemory(as: UInt8.self, repeating: 0x42)
    defer { buf.deallocate() }
    let small = UnsafeRawBufferPointer(rebasing: buf[..<64])

    // 1. Dual-stack
    let rx6 = udp6(); _ = bind6(rx6)
    let tx4 = udp4()
    _ = send(tx4, small, to: addr4("127.0.0.1", localPort(rx6)))
    var dual = "no datagram"
    if waitReadable(rx6, ms: 500), let r = receive(rx6, into: buf) {
        dual = "received from family \(r.fromFamily == AF_INET6 ? "AF_INET6" : "\(r.fromFamily)") v4-mapped=\(r.fromMapped)"
    }
    let rx4 = udp4(); _ = bind4(rx4)
    let tx6 = udp6(); _ = bind6(tx6)
    let sent6to4 = send(tx6, small, to: addr6("127.0.0.1", localPort(rx4)))
    let got4 = waitReadable(rx4, ms: 500) && receive(rx4, into: buf) != nil
    rep.add("dual-stack [::] V6ONLY=0: v4 sender → \(dual); dual-stack → ::ffff:127.0.0.1 sent=\(sent6to4) received=\(got4)")
    close(tx4); close(tx6)

    // 2. Ephemeral port on re-create
    var ports = [UInt16]()
    for _ in 0..<5 { let fd = udp6(); _ = bind6(fd); ports.append(localPort(fd)); close(fd) }
    rep.add("re-created socket ports: \(ports) → distinct: \(Set(ports).count == ports.count)")

    // 3. Buffer caps
    for (name, opt) in [("SO_RCVBUF", SO_RCVBUF), ("SO_SNDBUF", SO_SNDBUF)] {
        let fd = udp6()
        let dflt = getInt(fd, SOL_SOCKET, opt)
        var lo: Int32 = 65536, hi: Int32 = 64 << 20
        while lo < hi { let mid = lo + (hi - lo + 1) / 2; if setInt(fd, SOL_SOCKET, opt, mid) == 0 { lo = mid } else { hi = mid - 1 } }
        _ = setInt(fd, SOL_SOCKET, opt, lo)
        let backMax = getInt(fd, SOL_SOCKET, opt)
        let e8 = setInt(fd, SOL_SOCKET, opt, 8 << 20)
        rep.add("\(name): default \(fmtMB(dflt)); max accepted \(fmtMB(lo)) (readback \(fmtMB(backMax))); setting 8 MB → \(e8 == 0 ? "ok" : errnoString(e8))")
        close(fd)
    }

    // 4. SO_NET_SERVICE_TYPE → DSCP observed on loopback
    _ = setInt(rx4, IPPROTO_IP, IP_RECVTOS, 1)
    _ = setInt(rx6, IPPROTO_IPV6, IPV6_RECVTCLASS, 1)
    let recvTosOn6 = setInt(rx6, IPPROTO_IP, IP_RECVTOS, 1)
    rep.add("IP_RECVTOS on dual-stack socket: \(recvTosOn6 == 0 ? "ok" : errnoString(recvTosOn6))")
    let types: [(String, Int32)] = [("BE", NET_SERVICE_TYPE_BE), ("VI", NET_SERVICE_TYPE_VI), ("VO", NET_SERVICE_TYPE_VO),
                                    ("RV", NET_SERVICE_TYPE_RV), ("AV", NET_SERVICE_TYPE_AV), ("SIG", NET_SERVICE_TYPE_SIG)]
    for (name, st) in types {
        let s6 = udp6(); _ = bind6(s6)
        let rc = setInt(s6, SOL_SOCKET, SO_NET_SERVICE_TYPE, st)
        let back = getInt(s6, SOL_SOCKET, SO_NET_SERVICE_TYPE)
        _ = send(s6, small, to: addr6("127.0.0.1", localPort(rx4)))
        let v4 = waitReadable(rx4, ms: 300) ? receive(rx4, into: buf)?.tos : nil
        _ = send(s6, small, to: addr6("::1", localPort(rx6)))
        let v6 = waitReadable(rx6, ms: 300) ? receive(rx6, into: buf) : nil
        let dscp = { (x: Int?) in x.map { "0x\(String($0, radix: 16)) (DSCP \($0 >> 2))" } ?? "n/a" }
        rep.add("SO_NET_SERVICE_TYPE=\(name): set \(rc == 0 ? "ok" : errnoString(rc)), readback \(back); on-wire TOS via 127.0.0.1 \(dscp(v4)), TCLASS via ::1 \(dscp(v6?.tclass))")
        close(s6)
    }
    do {
        let s6 = udp6(); _ = bind6(s6)
        let a = setInt(s6, IPPROTO_IPV6, IPV6_TCLASS, 0xB8)
        let b = setInt(s6, IPPROTO_IP, IP_TOS, 0xB8)
        _ = send(s6, small, to: addr6("127.0.0.1", localPort(rx4)))
        let v4 = waitReadable(rx4, ms: 300) ? receive(rx4, into: buf)?.tos : nil
        _ = send(s6, small, to: addr6("::1", localPort(rx6)))
        let v6 = waitReadable(rx6, ms: 300) ? receive(rx6, into: buf)?.tclass : nil
        rep.add("explicit IPV6_TCLASS=0xB8 (\(a == 0 ? "ok" : errnoString(a))) / IP_TOS=0xB8 on dual-stack (\(b == 0 ? "ok" : errnoString(b))): v4 TOS \(v4.map { "0x" + String($0, radix: 16) } ?? "n/a"), v6 TCLASS \(v6.map { "0x" + String($0, radix: 16) } ?? "n/a")")
        close(s6)
    }

    // 5. Don't-fragment. Sends ≤ 4 datagrams to TEST-NET-1 / 2001:db8:: (reserved, unroutable).
    if allowExternalProbe {
        let df6 = udp6(); _ = bind6(df6)
        let e1 = setInt(df6, IPPROTO_IPV6, IPV6_DONTFRAG, 1)
        let e2 = setInt(df6, IPPROTO_IP, IP_DONTFRAG, 1)
        rep.add("dual-stack: IPV6_DONTFRAG \(e1 == 0 ? "ok" : errnoString(e1)); IP_DONTFRAG \(e2 == 0 ? "ok" : errnoString(e2))")
        func attempt(_ fd: Int32, _ size: Int, _ a: sockaddr_in6) -> String {
            let n = send(fd, UnsafeRawBufferPointer(rebasing: buf[..<size]), to: a)
            return n >= 0 ? "sent" : errnoString()
        }
        func attempt4(_ fd: Int32, _ size: Int, _ a: sockaddr_in) -> String {
            let n = send(fd, UnsafeRawBufferPointer(rebasing: buf[..<size]), to: a)
            return n >= 0 ? "sent" : errnoString()
        }
        let tn = addr6("192.0.2.1", 9)
        rep.add("dual-stack DF → ::ffff:192.0.2.1 payload 1472: \(attempt(df6, 1472, tn)); 1473: \(attempt(df6, 1473, tn))")
        let plain6 = udp6(); _ = bind6(plain6)
        rep.add("dual-stack no DF → ::ffff:192.0.2.1 payload 1473: \(attempt(plain6, 1473, tn))")
        let v4df = udp4(); _ = bind4(v4df)
        let e3 = setInt(v4df, IPPROTO_IP, IP_DONTFRAG, 1)
        rep.add("AF_INET IP_DONTFRAG (\(e3 == 0 ? "ok" : errnoString(e3))) → 192.0.2.1 payload 1473: \(attempt4(v4df, 1473, addr4("192.0.2.1", 9)))")
        rep.add("dual-stack DF → 2001:db8::1 payload 1453: \(attempt(df6, 1453, addr6("2001:db8::1", 9)))")
        close(df6); close(plain6); close(v4df)
    }

    // 6. EVFILT_READ wake latency on loopback (includes the send syscall + loopback path).
    let kq = kqueue()
    var ev = kevent64_s(ident: UInt64(rx6), filter: Int16(EVFILT_READ), flags: UInt16(EV_ADD | EV_CLEAR), fflags: 0, data: 0, udata: 0, ext: (0, 0))
    _ = kevent64(kq, &ev, 1, nil, 0, 0, nil)
    let port = localPort(rx6)
    let samples = quick ? 200 : 1000
    let lat = Mutex<[Double]>([])
    let rxfd = rx6
    let loop = spawnThread(qos: QOS_CLASS_USER_INTERACTIVE) {
        var out = kevent64_s()
        var got = [Double]()
        let b = UnsafeMutableRawBufferPointer.allocate(byteCount: 2048, alignment: 16)
        var timeout = timespec(tv_sec: 1, tv_nsec: 0)
        while got.count < samples {
            guard kevent64(kq, nil, 0, &out, 1, 0, &timeout) == 1 else { break }  // a lost datagram must not hang the probe
            while true {
                let n = recv(rxfd, b.baseAddress, b.count, 0)
                if n < 8 { break }
                got.append(Double(nowNs() &- b.load(as: UInt64.self)) / 1000)
            }
        }
        b.deallocate()
        lat.withLock { $0 = got }
    }
    onThread(qos: QOS_CLASS_USER_INTERACTIVE) {
        let tx = udp6(); _ = bind6(tx)
        let dst = addr6("127.0.0.1", port)
        var t: UInt64 = 0
        for _ in 0..<samples {
            usleep(500)
            t = nowNs()
            _ = withUnsafeBytes(of: &t) { send(tx, $0, to: dst) }
        }
        close(tx)
    }
    pthread_join(loop, nil)
    close(kq)
    rep.add("loopback send → EVFILT_READ wake → recv (µs): \(Distribution(lat.withLock { $0 }).summary)")
    close(rx4); close(rx6)
    return rep
}
