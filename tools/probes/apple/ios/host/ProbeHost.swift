// ProbeHost: the Mac side of the iPad probe (tools/probes/apple/ios).
//
// Listens on UDP (default port 47000) and
//   - logs every report and heartbeat from the iPad with the Mac's own arrival time,
//   - echoes 'J' jitter pings immediately and summarises each ping train's arrival gaps,
//   - answers "TPUT" requests with a paced burst of 1200-byte datagrams back to the sender.
//
// Build: swiftc -O -parse-as-library ProbeHost.swift -o probehost
// Run:   ./probehost [-port 47000] [-o ../../../results/ipad-<model>-<date>.txt]
import Darwin
import Foundation

@inline(__always) func nowNs() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
let startNs = nowNs()
func hostMs() -> Double {
    let base = startNs  // globals are lazy: initialise the base before sampling the clock
    return Double(nowNs() &- base) / 1e6
}

func percentile(_ xs: [Double], _ p: Double) -> Double {
    guard !xs.isEmpty else { return .nan }
    let s = xs.sorted()
    return s[min(s.count - 1, Int(p / 100 * Double(s.count - 1) + 0.5))]
}

final class Log: @unchecked Sendable {
    let lock = NSLock()
    let handle: FileHandle?
    init(path: String?) {
        if let path {
            FileManager.default.createFile(atPath: path, contents: nil)
            handle = FileHandle(forWritingAtPath: path)
        } else { handle = nil }
    }
    func write(_ s: String, echo: Bool = true) {
        lock.lock(); defer { lock.unlock() }
        let line = String(format: "%11.1f  ", hostMs()) + s
        if echo { print(line); fflush(stdout) }
        handle?.write((line + "\n").data(using: .utf8)!)
    }
}

func describe(_ ss: sockaddr_storage) -> String {
    var s = ss
    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST)), serv = [CChar](repeating: 0, count: Int(NI_MAXSERV))
    _ = withUnsafePointer(to: &s) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getnameinfo($0, socklen_t(ss.ss_len), &host, socklen_t(host.count), &serv, socklen_t(serv.count), NI_NUMERICHOST | NI_NUMERICSERV)
        }
    }
    return "\(String(cString: host)):\(String(cString: serv))"
}

final class Host: @unchecked Sendable {
    let fd: Int32
    let log: Log
    // Ping train state (single receive thread, no lock needed).
    var pingArrivals: [Double] = []
    var lastPingMs = 0.0
    var lastHeartbeat: [String: Double] = [:]

    init(port: UInt16, log: Log) {
        self.log = log
        fd = socket(AF_INET6, SOCK_DGRAM, IPPROTO_UDP)
        var off: Int32 = 0, big: Int32 = 8 << 20
        setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &off, 4)
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &big, 4)
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &big, 4)
        var a = sockaddr_in6()
        a.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        a.sin6_family = sa_family_t(AF_INET6)
        a.sin6_port = port.bigEndian
        let r = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } }
        precondition(r == 0, "bind failed: \(String(cString: strerror(errno)))")
        var tv = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    func run() {
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            var ss = sockaddr_storage()
            var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let n = withUnsafeMutablePointer(to: &ss) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &len) }
            }
            let t = hostMs()
            if n < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { flushPingTrain(now: t); continue }
                log.write("recvfrom errno \(errno) \(String(cString: strerror(errno)))")
                continue
            }
            if n == 0 { continue }
            if buf[0] == UInt8(ascii: "J") {
                // Echo first, account after, so the account never delays the echo.
                _ = withUnsafePointer(to: &ss) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, buf, n, 0, $0, len) }
                }
                if !pingArrivals.isEmpty && t - lastPingMs > 1000 { flushPingTrain(now: t) }
                pingArrivals.append(t)
                lastPingMs = t
                continue
            }
            flushPingTrain(now: t)
            let text = String(decoding: buf[0..<n], as: UTF8.self)
            let from = describe(ss)
            if text.hasPrefix("HB ") {
                if let last = lastHeartbeat[from], t - last > 250 {
                    log.write(String(format: "heartbeat gap %.0f ms from %@ — %@", t - last, from, text))
                } else {
                    log.write("\(from) \(text)", echo: false)
                }
                lastHeartbeat[from] = t
            } else if text.hasPrefix("TPUT ") {
                log.write("\(from) \(text)")
                startBurst(request: text, to: ss, len: len)
            } else {
                log.write("\(from) \(text)")
            }
        }
    }

    private func flushPingTrain(now: Double) {
        guard !pingArrivals.isEmpty, now - lastPingMs > 1000 else { return }
        var gaps: [Double] = []
        for i in 1..<pingArrivals.count { gaps.append(pingArrivals[i] - pingArrivals[i - 1]) }
        let big = gaps.enumerated().filter { $0.element > 20 }
        let times = big.prefix(12).map { String(format: "%.0f", pingArrivals[$0.offset + 1] - pingArrivals[0]) }.joined(separator: ",")
        var intervals: [Double] = []
        var lastBig = -1.0
        for (i, _) in big {
            let at = pingArrivals[i + 1]
            if lastBig >= 0 && at - lastBig > 100 { intervals.append(at - lastBig) }
            if lastBig < 0 || at - lastBig > 100 { lastBig = at }
        }
        log.write(String(format: "PING_TRAIN_UPLINK count=%d span=%.1fs gap_p50=%.2fms gap_p99=%.2fms gap_max=%.1fms gaps_over_20ms=%d spike_interval_p50=%.0fms first_spikes_at_ms=[%@]",
                         pingArrivals.count, (pingArrivals.last! - pingArrivals.first!) / 1000, percentile(gaps, 50), percentile(gaps, 99),
                         gaps.max() ?? 0, big.count, percentile(intervals, 50), times))
        pingArrivals.removeAll()
    }

    /// "TPUT id=<n> rate=<mbps> secs=<s> size=<bytes>" -> paced datagrams back to the sender.
    private func startBurst(request: String, to ss: sockaddr_storage, len: socklen_t) {
        var kv: [String: Double] = [:]
        for part in request.split(separator: " ").dropFirst() {
            let p = part.split(separator: "=")
            if p.count == 2, let v = Double(p[1]) { kv[String(p[0])] = v }
        }
        let id = UInt32(kv["id"] ?? 0), mbps = kv["rate"] ?? 100, secs = kv["secs"] ?? 3, size = Int(kv["size"] ?? 1200)
        let fd = self.fd, log = self.log
        let t = Thread {
            var dst = ss
            let perMs = mbps * 1e6 / 8 / Double(size) / 1000
            var pkt = [UInt8](repeating: 0x5A, count: size)
            pkt[0] = UInt8(ascii: "T")
            withUnsafeBytes(of: id.bigEndian) { for i in 0..<4 { pkt[1 + i] = $0[i] } }
            let begin = nowNs()
            let endNs = begin + UInt64(secs * 1e9)
            var seq: UInt32 = 0
            var errors = 0
            while nowNs() < endNs {
                let due = Double(nowNs() - begin) / 1e6 * perMs
                while Double(seq) < due {
                    withUnsafeBytes(of: seq.bigEndian) { for i in 0..<4 { pkt[5 + i] = $0[i] } }
                    let ts = nowNs()
                    withUnsafeBytes(of: ts.bigEndian) { for i in 0..<8 { pkt[9 + i] = $0[i] } }
                    let r = withUnsafePointer(to: &dst) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, pkt, size, 0, $0, len) } }
                    if r < 0 { errors += 1 }
                    seq += 1
                }
                usleep(200)
            }
            var end = [UInt8](repeating: 0, count: 9)
            end[0] = UInt8(ascii: "E")
            withUnsafeBytes(of: id.bigEndian) { for i in 0..<4 { end[1 + i] = $0[i] } }
            withUnsafeBytes(of: seq.bigEndian) { for i in 0..<4 { end[5 + i] = $0[i] } }
            for _ in 0..<5 {
                _ = withUnsafePointer(to: &dst) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, end, end.count, 0, $0, len) } }
                usleep(20_000)
            }
            log.write(String(format: "TPUT_SENT id=%u rate=%.0fMbps secs=%.1f sent=%u send_errors=%d", id, mbps, secs, seq, errors))
        }
        t.qualityOfService = .userInteractive
        t.start()
    }
}

@main struct Main {
    static func main() {
        var port: UInt16 = 47000
        var out: String? = nil
        var args = CommandLine.arguments.dropFirst().makeIterator()
        while let a = args.next() {
            switch a {
            case "-port": port = UInt16(args.next() ?? "47000") ?? 47000
            case "-o": out = args.next()
            default: break
            }
        }
        let log = Log(path: out)
        log.write("probehost listening on udp/\(port)\(out.map { ", writing \($0)" } ?? "")")
        Host(port: port, log: log).run()
    }
}
