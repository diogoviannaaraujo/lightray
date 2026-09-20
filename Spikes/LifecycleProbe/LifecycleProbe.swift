// iOS lifecycle probe for the reconnect design (Definition.md, "Reconnect").
// A single kqueue loop thread, shaped like the planned Transport runtime, heartbeats every
// 100 ms to a UDP listener on the Mac (the Simulator shares the host's network stack) and
// reports what happens around didEnterBackground / suspension / willEnterForeground:
//   - does PARK sent from didEnterBackground get out?
//   - how long does the process keep running after backgrounding (with / without a bg task)?
//   - does the socket survive suspension (queued datagrams, send/recv errors, SO_ERROR)?
//   - does a replacement socket (new port) work immediately on foreground?
// Everything is also appended to Documents/probe.log, which survives a broken socket.

import Darwin
import Network
import SwiftUI
import UIKit

let hostPort: UInt16 = 47000
let IPV6_DONTFRAG_: Int32 = 62  // not imported into Swift (__APPLE_USE_RFC_3542)

// MARK: - Time

let timebase: (UInt64, UInt64) = {
    var tb = mach_timebase_info_data_t()
    mach_timebase_info(&tb)
    return (UInt64(tb.numer), UInt64(tb.denom))
}()
let launchTicks = mach_continuous_time()
func nowMs() -> Double {
    let base = launchTicks  // globals are lazy: read the base before sampling the clock
    return Double((mach_continuous_time() &- base) &* timebase.0 / timebase.1) / 1e6
}

// MARK: - File log

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
        handle?.write(String(format: "%10.1f ", nowMs()).data(using: .utf8)! + s.data(using: .utf8)! + Data([0x0A]))
    }
}

// MARK: - Loop

final class Loop: @unchecked Sendable {
    enum Command { case background(bgRemaining: Double), foreground, note(String) }

    let kq = kqueue()
    var fd: Int32 = -1
    var port: UInt16 = 0
    var seq = 0
    var rx = 0
    var phase = "fg"
    var sendErrors: [Int32: Int] = [:]
    var lastTick = 0.0, maxGap = 0.0
    let dest: sockaddr_in6
    private let lock = NSLock()
    private var commands: [Command] = []

    init() {
        var a = sockaddr_in6()
        a.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        a.sin6_family = sa_family_t(AF_INET6)
        a.sin6_port = hostPort.bigEndian
        inet_pton(AF_INET6, "::ffff:127.0.0.1", &a.sin6_addr)
        dest = a
    }

    func start() {
        openSocket()
        var evs = [
            kevent64_s(ident: 1, filter: Int16(EVFILT_TIMER), flags: UInt16(EV_ADD), fflags: UInt32(NOTE_NSECONDS | NOTE_CRITICAL),
                       data: 100_000_000, udata: 0, ext: (0, 0)),
            kevent64_s(ident: 2, filter: Int16(EVFILT_USER), flags: UInt16(EV_ADD | EV_CLEAR), fflags: 0, data: 0, udata: 0, ext: (0, 0)),
        ]
        kevent64(kq, &evs, 2, nil, 0, 0, nil)
        let t = Thread { self.run() }
        t.qualityOfService = .userInteractive
        t.name = "lightray.loop"
        t.start()
    }

    /// Called from any thread; wakes the loop. Wakes may coalesce, so the loop drains the queue.
    func post(_ c: Command) {
        lock.lock(); commands.append(c); lock.unlock()
        var trig = kevent64_s(ident: 2, filter: Int16(EVFILT_USER), flags: 0, fflags: UInt32(NOTE_TRIGGER), data: 0, udata: 0, ext: (0, 0))
        kevent64(kq, &trig, 1, nil, 0, 0, nil)
    }

    private func openSocket() {
        fd = socket(AF_INET6, SOCK_DGRAM, IPPROTO_UDP)
        var off: Int32 = 0, on: Int32 = 1, vi: Int32 = NET_SERVICE_TYPE_VI, big: Int32 = 8 << 20
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

    /// Returns 0 or errno.
    @discardableResult
    private func send(_ msg: String, on sock: Int32? = nil) -> Int32 {
        let line = String(format: "t=%.1f seq=%d phase=%@ port=%d ", nowMs(), seq, phase, port) + msg
        var d = dest
        let n = line.withCString { p in
            withUnsafePointer(to: &d) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(sock ?? fd, p, strlen(p), 0, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            } }
        }
        let err: Int32 = n < 0 ? errno : 0
        if err != 0 { sendErrors[err, default: 0] += 1 }
        if !msg.hasPrefix("HB") || err != 0 { FileLog.shared.write("\(line) -> \(err == 0 ? "sent" : "errno \(err) \(String(cString: strerror(err)))")") }
        return err
    }

    /// Drains readable datagrams; returns (count, terminal errno or 0 for EAGAIN).
    private func drain(_ sock: Int32) -> (Int, Int32) {
        var buf = [UInt8](repeating: 0, count: 2048)
        var count = 0
        while true {
            let n = recv(sock, &buf, buf.count, 0)
            if n >= 0 { count += 1; continue }
            return (count, errno == EAGAIN ? 0 : errno)
        }
    }

    private func run() {
        var events = [kevent64_s](repeating: kevent64_s(), count: 8)
        while true {
            let n = kevent64(kq, nil, 0, &events, 8, 0, nil)
            if n < 0 { FileLog.shared.write("kevent64 errno \(errno)"); usleep(100_000); continue }
            for e in events[0..<Int(n)] {
                switch Int32(e.filter) {
                case EVFILT_TIMER:
                    let t = nowMs()
                    if lastTick > 0 { maxGap = max(maxGap, t - lastTick) }
                    lastTick = t
                    seq += 1
                    send("HB rx=\(rx)")
                case EVFILT_READ:
                    let (c, err) = drain(Int32(e.ident))
                    rx += c
                    if err != 0 { FileLog.shared.write("recv errno \(err) \(String(cString: strerror(err)))") }
                case EVFILT_USER:
                    lock.lock(); let cmds = commands; commands.removeAll(); lock.unlock()
                    for c in cmds { handle(c) }
                default: break
                }
            }
        }
    }

    private func handle(_ c: Command) {
        switch c {
        case .note(let s):
            send(s)
        case .background(let remaining):
            phase = "bg"
            maxGap = 0
            send(String(format: "PARK backgroundTimeRemaining=%.1f", remaining))
        case .foreground:
            // Probe the old socket before replacing it.
            let gap = maxGap
            var soerr: Int32 = 0
            var len = socklen_t(4)
            let gs = getsockopt(fd, SOL_SOCKET, SO_ERROR, &soerr, &len)
            let (queued, recvErr) = drain(fd)
            let oldFd = fd, oldPort = port
            phase = "fg"
            let oldSend = send("OLD_SOCKET_PROBE", on: oldFd)
            close(oldFd)  // closing also removes its kevent
            openSocket()
            let errs = sendErrors.map { "\($0.key):\($0.value)" }.joined(separator: ",")
            send(String(format: "RESUME maxTimerGapWhileBg=%.0fms oldPort=%d oldSend=%d oldRecvErr=%d queuedEchoesOnOld=%d SO_ERROR=%d(gs=%d) sendErrorsSoFar=[%@] newPort=%d",
                        gap, oldPort, oldSend, recvErr, queued, soerr, gs, errs, port))
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, UIApplicationDelegate {
    let loop = Loop()
    let path = NWPathMonitor()
    var bgTask: UIBackgroundTaskIdentifier = .invalid
    let useBgTask = ProcessInfo.processInfo.arguments.contains("-bgtask")

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        _ = launchTicks
        FileLog.shared.write("---- LAUNCH pid=\(getpid()) bgtask=\(useBgTask)")
        loop.start()
        loop.post(.note("LAUNCH pid=\(getpid()) bgtask=\(useBgTask)"))
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [unowned self] _ in didEnterBackground() }
        nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [unowned self] _ in
            FileLog.shared.write("willEnterForeground")
            loop.post(.foreground)
        }
        nc.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { [unowned self] _ in
            FileLog.shared.write("willTerminate")
            loop.post(.note("WILL_TERMINATE"))
        }
        path.pathUpdateHandler = { [unowned self] p in
            loop.post(.note("PATH status=\(p.status) ifaces=\(p.availableInterfaces.map(\.name)) expensive=\(p.isExpensive)"))
        }
        path.start(queue: DispatchQueue(label: "path"))
        return true
    }

    private func didEnterBackground() {
        let app = UIApplication.shared
        let remaining = app.backgroundTimeRemaining
        FileLog.shared.write(String(format: "didEnterBackground backgroundTimeRemaining=%.1f", remaining))
        if useBgTask {
            bgTask = app.beginBackgroundTask(withName: "lightray.park") { [unowned self] in
                FileLog.shared.write(String(format: "bg task expired, remaining=%.1f", UIApplication.shared.backgroundTimeRemaining))
                loop.post(.note("BGTASK_EXPIRED"))
                UIApplication.shared.endBackgroundTask(bgTask)
                bgTask = .invalid
            }
            loop.post(.note(String(format: "BGTASK_BEGIN backgroundTimeRemaining=%.1f", app.backgroundTimeRemaining)))
        }
        loop.post(.background(bgRemaining: remaining))
    }
}

@main
struct LifecycleProbeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 12) {
                Text("Lightray lifecycle probe").font(.title2.bold())
                Text("Heartbeats every 100 ms to 127.0.0.1:\(hostPort).\nPress Home, wait, then reopen.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
            }.padding()
        }
    }
}
