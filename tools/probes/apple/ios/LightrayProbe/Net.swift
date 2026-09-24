// One kqueue thread owns the socket, shaped like a Lightray client runtime: heartbeats every
// 100 ms, a 1 kHz jitter ping train on demand, throughput bursts on demand, and the socket
// replacement a resume performs. Everything it learns goes to the Mac host and Documents/probe.log.
import Darwin
import Foundation

let hostPort: UInt16 = 47000
let IPV6_DONTFRAG_: Int32 = 62  // not imported into Swift (__APPLE_USE_RFC_3542)

let timebase: (UInt64, UInt64) = {
    var tb = mach_timebase_info_data_t()
    mach_timebase_info(&tb)
    return (UInt64(tb.numer), UInt64(tb.denom))
}()
let launchTicks = mach_continuous_time()

/// Milliseconds since launch on the continuous clock (keeps counting while suspended).
func nowMs() -> Double {
    let base = launchTicks
    return Double((mach_continuous_time() &- base) &* timebase.0 / timebase.1) / 1e6
}

@inline(__always) func monoNs() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

func percentile(_ xs: [Double], _ p: Double) -> Double {
    guard !xs.isEmpty else { return .nan }
    let s = xs.sorted()
    return s[min(s.count - 1, Int(p / 100 * Double(s.count - 1) + 0.5))]
}

final class FileLog: @unchecked Sendable {
    static let shared = FileLog()
    private let lock = NSLock()
    private let handle: FileHandle?
    init() {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("probe.log")
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
    }
    func write(_ s: String) {
        lock.lock(); defer { lock.unlock() }
        handle?.write(Data((String(format: "%10.1f ", nowMs()) + s + "\n").utf8))
    }
}

enum Report {
    /// A result line: to the file, to the Mac host, and to the on-screen log.
    static func line(_ s: String) {
        FileLog.shared.write(s)
        NetLoop.shared.post(.text("R " + s))
        DispatchQueue.main.async { ProbeModel.shared.append(s) }
    }
}

final class NetLoop: @unchecked Sendable {
    static let shared = NetLoop()

    enum Command {
        case setHost(String)
        case text(String)
        case background(remaining: Double)
        case foreground
        case jitter(seconds: Int, hz: Int)
        case throughput(id: UInt32, mbps: Int, seconds: Int)
    }

    private let kq = kqueue()
    private var fd: Int32 = -1
    private var port: UInt16 = 0
    private var dest = sockaddr_in6()
    private var hostSet = false
    private var started = false
    private var seq = 0
    private var phase = "fg"
    private var backgroundedAt = 0.0
    private var lastTick = 0.0, maxGap = 0.0
    private var sendErrors: [Int32: Int] = [:]
    private let lock = NSLock()
    private var commands: [Command] = []

    // Jitter train.
    private var jitterSeq: UInt32 = 0
    private var jitterEnd = 0.0
    private var jitterStart = 0.0
    private var jitterSent: [UInt64] = []
    private var jitterRtt: [(at: Double, rtt: Double)] = []

    // Throughput burst.
    private var tputId: UInt32 = 0
    private var tputMbps = 0, tputSecs = 0
    private var tputRecv = 0, tputBytes = 0, tputGaps = 0, tputHighest: Int64 = -1
    private var tputFirst = 0.0, tputLast = 0.0, tputMaxGap = 0.0, tputSentByHost: UInt32 = 0
    private var tputDone = true

    private enum Timer: UInt64 { case heartbeat = 1, user = 2, jitter = 3, jitterDone = 4, tputDone = 5 }

    func start() {
        guard !started else { return }
        started = true
        signal(SIGPIPE, SIG_IGN)
        openSocket()
        var evs = [
            kevent64_s(ident: Timer.heartbeat.rawValue, filter: Int16(EVFILT_TIMER), flags: UInt16(EV_ADD), fflags: UInt32(NOTE_NSECONDS | NOTE_CRITICAL),
                       data: 100_000_000, udata: 0, ext: (0, 0)),
            kevent64_s(ident: Timer.user.rawValue, filter: Int16(EVFILT_USER), flags: UInt16(EV_ADD | EV_CLEAR), fflags: 0, data: 0, udata: 0, ext: (0, 0)),
        ]
        kevent64(kq, &evs, 2, nil, 0, 0, nil)
        let t = Thread { self.run() }
        t.qualityOfService = .userInteractive
        t.name = "lightray.probe.loop"
        t.start()
    }

    /// Any thread. Wakes may coalesce, so the loop drains the whole queue.
    func post(_ c: Command) {
        lock.lock(); commands.append(c); lock.unlock()
        var trig = kevent64_s(ident: Timer.user.rawValue, filter: Int16(EVFILT_USER), flags: 0, fflags: UInt32(NOTE_TRIGGER), data: 0, udata: 0, ext: (0, 0))
        kevent64(kq, &trig, 1, nil, 0, 0, nil)
    }

    // MARK: Socket

    private func openSocket() {
        fd = socket(AF_INET6, SOCK_DGRAM, IPPROTO_UDP)
        var off: Int32 = 0, on: Int32 = 1, vi: Int32 = NET_SERVICE_TYPE_VI, big: Int32 = 8 << 20
        // iPadOS reclaims a suspended app's sockets; sending on a reclaimed one raises SIGPIPE.
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, 4)
        setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &off, 4)
        setsockopt(fd, IPPROTO_IPV6, IPV6_DONTFRAG_, &on, 4)
        setsockopt(fd, SOL_SOCKET, SO_NET_SERVICE_TYPE, &vi, 4)
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &big, 4)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var any = sockaddr_in6()
        any.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        any.sin6_family = sa_family_t(AF_INET6)
        _ = withUnsafePointer(to: &any) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } }
        var ss = sockaddr_in6()
        var len = socklen_t(MemoryLayout<sockaddr_in6>.size)
        _ = withUnsafeMutablePointer(to: &ss) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        port = UInt16(bigEndian: ss.sin6_port)
        var ev = kevent64_s(ident: UInt64(fd), filter: Int16(EVFILT_READ), flags: UInt16(EV_ADD | EV_CLEAR), fflags: 0, data: 0, udata: 0, ext: (0, 0))
        kevent64(kq, &ev, 1, nil, 0, 0, nil)
    }

    var receiveBufferBytes: Int32 {
        var v: Int32 = 0
        var len = socklen_t(4)
        getsockopt(fd, SOL_SOCKET, SO_RCVBUF, &v, &len)
        return v
    }

    private func setHost(_ s: String) {
        var a = sockaddr_in6()
        a.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        a.sin6_family = sa_family_t(AF_INET6)
        a.sin6_port = hostPort.bigEndian
        let ok = s.contains(":") ? inet_pton(AF_INET6, s, &a.sin6_addr) : inet_pton(AF_INET6, "::ffff:" + s, &a.sin6_addr)
        hostSet = ok == 1
        dest = a
        FileLog.shared.write("host \(s) valid=\(hostSet)")
    }

    @discardableResult
    private func sendRaw(_ bytes: UnsafeRawBufferPointer, on sock: Int32? = nil) -> Int32 {
        guard hostSet else { return EDESTADDRREQ }
        var d = dest
        let n = withUnsafePointer(to: &d) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(sock ?? fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        let err: Int32 = n < 0 ? errno : 0
        if err != 0 { sendErrors[err, default: 0] += 1 }
        return err
    }

    @discardableResult
    private func sendText(_ s: String, on sock: Int32? = nil) -> Int32 {
        var data = Array(s.utf8)
        return data.withUnsafeMutableBytes { sendRaw(UnsafeRawBufferPointer($0), on: sock) }
    }

    // MARK: Loop

    private func run() {
        var events = [kevent64_s](repeating: kevent64_s(), count: 16)
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = kevent64(kq, nil, 0, &events, 16, 0, nil)
            if n < 0 { FileLog.shared.write("kevent64 errno \(errno)"); usleep(100_000); continue }
            for e in events[0..<Int(n)] {
                switch (Int32(e.filter), e.ident) {
                case (EVFILT_TIMER, Timer.heartbeat.rawValue):
                    let t = nowMs()
                    if lastTick > 0 { maxGap = max(maxGap, t - lastTick) }
                    lastTick = t
                    seq += 1
                    sendText(String(format: "HB seq=%d t=%.1f phase=%@ port=%d", seq, t, phase, port))
                case (EVFILT_TIMER, Timer.jitter.rawValue):
                    jitterTick()
                case (EVFILT_TIMER, Timer.jitterDone.rawValue):
                    finishJitter()
                case (EVFILT_TIMER, Timer.tputDone.rawValue):
                    finishThroughput()
                case (EVFILT_READ, _):
                    drain(Int32(e.ident), &buf)
                case (EVFILT_USER, _):
                    lock.lock(); let cmds = commands; commands.removeAll(); lock.unlock()
                    for c in cmds { handle(c) }
                default: break
                }
            }
        }
    }

    private func drain(_ sock: Int32, _ buf: inout [UInt8]) {
        while true {
            let n = recv(sock, &buf, buf.count, 0)
            if n < 0 {
                if errno != EAGAIN { FileLog.shared.write("recv errno \(errno) \(String(cString: strerror(errno)))") }
                return
            }
            guard n > 0 else { continue }
            let arrival = nowMs()
            switch buf[0] {
            case UInt8(ascii: "J") where n >= 13:
                let s = buf.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: 1, as: UInt32.self)) }
                let sent = buf.withUnsafeBytes { UInt64(bigEndian: $0.loadUnaligned(fromByteOffset: 5, as: UInt64.self)) }
                jitterRtt.append((at: arrival - jitterStart, rtt: Double(monoNs() &- sent) / 1e6))
                _ = s
            case UInt8(ascii: "T") where n >= 17:
                let id = buf.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: 1, as: UInt32.self)) }
                guard id == tputId, !tputDone else { continue }
                let s = Int64(buf.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: 5, as: UInt32.self)) })
                if tputRecv == 0 { tputFirst = arrival } else { tputMaxGap = max(tputMaxGap, arrival - tputLast) }
                tputLast = arrival
                tputRecv += 1
                tputBytes += n
                if s > tputHighest + 1 { tputGaps += 1 }
                tputHighest = max(tputHighest, s)
            case UInt8(ascii: "E") where n >= 9:
                let id = buf.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: 1, as: UInt32.self)) }
                guard id == tputId, !tputDone, tputSentByHost == 0 else { continue }
                tputSentByHost = buf.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: 5, as: UInt32.self)) }
                oneShot(.tputDone, ms: 300)
            default:
                break
            }
        }
    }

    private func oneShot(_ t: Timer, ms: Int) {
        var ev = kevent64_s(ident: t.rawValue, filter: Int16(EVFILT_TIMER), flags: UInt16(EV_ADD | EV_ONESHOT), fflags: UInt32(NOTE_NSECONDS),
                            data: Int64(ms) * 1_000_000, udata: 0, ext: (0, 0))
        kevent64(kq, &ev, 1, nil, 0, 0, nil)
    }

    private func handle(_ c: Command) {
        switch c {
        case .setHost(let s):
            setHost(s)
        case .text(let s):
            sendText(s)
        case .background(let remaining):
            phase = "bg"
            backgroundedAt = nowMs()
            maxGap = 0
            let err = sendText(String(format: "PARK t=%.1f backgroundTimeRemaining=%.1f", backgroundedAt, remaining))
            FileLog.shared.write("PARK sent err=\(err)")
        case .foreground:
            guard phase == "bg" else { return }  // scene apps also report foreground right after launch
            FileLog.shared.write("foreground: probing old socket")
            let away = nowMs() - backgroundedAt
            let gap = maxGap
            var soerr: Int32 = 0
            var len = socklen_t(4)
            let gs = getsockopt(fd, SOL_SOCKET, SO_ERROR, &soerr, &len)
            var buf = [UInt8](repeating: 0, count: 2048)
            var queued = 0
            var recvErr: Int32 = 0
            while true {
                let n = recv(fd, &buf, buf.count, 0)
                if n >= 0 { queued += 1; continue }
                recvErr = errno == EAGAIN ? 0 : errno
                break
            }
            let oldFd = fd, oldPort = port
            phase = "fg"
            let t0 = nowMs()
            let oldSend = sendText("OLD_SOCKET_PROBE", on: oldFd)
            close(oldFd)
            openSocket()
            let newSend = sendText("NEW_SOCKET_FIRST_SEND")
            let t1 = nowMs()
            let errs = sendErrors.map { "\($0.key):\($0.value)" }.sorted().joined(separator: ",")
            let line = String(format: "RESUME away_ms=%.0f max_timer_gap_while_bg_ms=%.0f old_port=%d old_send_errno=%d old_recv_errno=%d queued_on_old=%d SO_ERROR=%d(gs=%d) new_port=%d new_send_errno=%d replace_ms=%.2f send_errors=[%@]",
                              away, gap, oldPort, oldSend, recvErr, queued, soerr, gs, port, newSend, t1 - t0, errs)
            sendText("R " + line)
            FileLog.shared.write(line)
            DispatchQueue.main.async { ProbeModel.shared.append(line) }
        case .jitter(let seconds, let hz):
            jitterSeq = 0
            jitterSent = []
            jitterRtt = []
            jitterStart = nowMs()
            jitterEnd = jitterStart + Double(seconds) * 1000
            var ev = kevent64_s(ident: Timer.jitter.rawValue, filter: Int16(EVFILT_TIMER), flags: UInt16(EV_ADD), fflags: UInt32(NOTE_NSECONDS | NOTE_CRITICAL),
                                data: Int64(1_000_000_000 / hz), udata: 0, ext: (0, 0))
            kevent64(kq, &ev, 1, nil, 0, 0, nil)
        case .throughput(let id, let mbps, let seconds):
            tputId = id; tputMbps = mbps; tputSecs = seconds
            tputRecv = 0; tputBytes = 0; tputGaps = 0; tputHighest = -1
            tputFirst = 0; tputLast = 0; tputMaxGap = 0; tputSentByHost = 0
            tputDone = false
            sendText("TPUT id=\(id) rate=\(mbps) secs=\(seconds) size=1200")
            oneShot(.tputDone, ms: seconds * 1000 + 3000)  // safety net if the end marker is lost
        }
    }

    // MARK: Jitter

    private func jitterTick() {
        let t = nowMs()
        if t >= jitterEnd {
            var ev = kevent64_s(ident: Timer.jitter.rawValue, filter: Int16(EVFILT_TIMER), flags: UInt16(EV_DELETE), fflags: 0, data: 0, udata: 0, ext: (0, 0))
            kevent64(kq, &ev, 1, nil, 0, 0, nil)
            oneShot(.jitterDone, ms: 500)
            return
        }
        var pkt = [UInt8](repeating: 0, count: 13)
        pkt[0] = UInt8(ascii: "J")
        let s = jitterSeq
        let ns = monoNs()
        withUnsafeBytes(of: s.bigEndian) { for i in 0..<4 { pkt[1 + i] = $0[i] } }
        withUnsafeBytes(of: ns.bigEndian) { for i in 0..<8 { pkt[5 + i] = $0[i] } }
        pkt.withUnsafeBytes { _ = sendRaw($0) }
        jitterSent.append(ns)
        jitterSeq += 1
    }

    private func finishJitter() {
        let rtts = jitterRtt.map(\.rtt)
        let p50 = percentile(rtts, 50)
        let threshold = max(p50 * 3, p50 + 15)
        var clusters: [Double] = []
        var spikeTime = 0.0
        var lastSpike = -1000.0
        for s in jitterRtt where s.rtt > threshold {
            if s.at - lastSpike > 100 { clusters.append(s.at) }
            lastSpike = s.at
            spikeTime += 1
        }
        var intervals: [Double] = []
        for i in 1..<max(1, clusters.count) { intervals.append(clusters[i] - clusters[i - 1]) }
        let first = clusters.prefix(15).map { String(format: "%.0f", $0) }.joined(separator: ",")
        Report.line(String(format: "JITTER sent=%d echoed=%d rtt_p50=%.2fms p90=%.2fms p99=%.2fms max=%.1fms spike_threshold=%.1fms spike_clusters=%d spike_interval_p50=%.0fms pings_in_spikes=%.0f first_clusters_at_ms=[%@]",
                                jitterSent.count, rtts.count, p50, percentile(rtts, 90), percentile(rtts, 99), rtts.max() ?? .nan,
                                threshold, clusters.count, percentile(intervals, 50), spikeTime, first))
        DispatchQueue.main.async { ProbeModel.shared.jitterFinished() }
    }

    // MARK: Throughput

    private func finishThroughput() {
        guard !tputDone else { return }
        tputDone = true
        let span = max(0.001, (tputLast - tputFirst) / 1000)
        let sent = Int(tputSentByHost)
        let loss = sent > 0 ? 100 * Double(max(0, sent - tputRecv)) / Double(sent) : .nan
        Report.line(String(format: "THROUGHPUT id=%u offered=%dMbps secs=%d host_sent=%d received=%d loss=%.2f%% goodput=%.1fMbps seq_gaps=%d max_arrival_gap_ms=%.1f so_rcvbuf=%d",
                           tputId, tputMbps, tputSecs, sent, tputRecv, loss, Double(tputBytes) * 8 / span / 1e6, tputGaps, tputMaxGap, receiveBufferBytes))
        DispatchQueue.main.async { ProbeModel.shared.throughputFinished() }
    }
}
