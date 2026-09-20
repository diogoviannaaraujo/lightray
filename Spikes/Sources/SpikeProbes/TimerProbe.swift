import Darwin
import Foundation
import Synchronization

// Clocks: per-call cost and whether each clock keeps counting across sleep.
public func clockProbe() -> Report {
    var rep = Report("Clocks — cost per read and sleep behaviour")
    let iters = 2_000_000
    func row(_ name: String, _ f: @escaping () -> UInt64) {
        let r = bench(iterations: iters, repeats: 3) { _ in blackHole(f()) }
        rep.add("\(name.padding(toLength: 44, withPad: " ", startingAt: 0)) \(r.description)")
    }
    row("clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)") { clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) }
    row("clock_gettime_nsec_np(CLOCK_MONOTONIC)") { clock_gettime_nsec_np(CLOCK_MONOTONIC) }
    row("clock_gettime_nsec_np(CLOCK_UPTIME_RAW)") { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
    row("mach_continuous_time() (ticks)") { mach_continuous_time() }
    row("mach_absolute_time() (ticks)") { mach_absolute_time() }
    row("ContinuousClock.now") { UInt64(bitPattern: ContinuousClock.now.duration(to: ContinuousClock.now).components.attoseconds) }
    var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
    let asleep = Double(Int64(bitPattern: clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) &- clock_gettime_nsec_np(CLOCK_UPTIME_RAW))) / 1e9
    let contVsRaw = Int64(bitPattern: mach_continuous_time() &* UInt64(tb.numer) / UInt64(tb.denom) &- clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW))
    rep.add("mach timebase \(tb.numer)/\(tb.denom); MONOTONIC_RAW − UPTIME_RAW = \(String(format: "%.1f", asleep)) s (= time asleep since boot; 0 means no sleep observed yet)")
    rep.add("mach_continuous_time vs MONOTONIC_RAW offset: \(contVsRaw) ns (same timeline)")
    return rep
}

// Spike 3: kqueue timer wake precision, and EVFILT_USER cross-thread wake latency.

enum TimerMode: String, CaseIterable, Sendable {
    case keventTimeout = "kevent timeout"
    case evfiltTimer = "EVFILT_TIMER ns"
    case evfiltTimerCritical = "EVFILT_TIMER ns+CRITICAL"
    case evfiltTimerLeeway0 = "EVFILT_TIMER ns+LEEWAY 0"
    case evfiltTimerLeeway1us = "EVFILT_TIMER ns+LEEWAY 1µs"
    case evfiltTimerLeeway50us = "EVFILT_TIMER ns+LEEWAY 50µs"
}

/// Lateness samples (µs) for one-shot waits of `intervalNs` on the calling thread.
func timerLateness(mode: TimerMode, intervalNs: Int, samples: Int) -> [Double] {
    let kq = kqueue()
    defer { close(kq) }
    var out = [Double]()
    out.reserveCapacity(samples)
    var ev = kevent64_s()
    for _ in 0..<samples {
        let t0 = nowNs()
        let target = t0 + UInt64(intervalNs)
        switch mode {
        case .keventTimeout:
            var ts = timespec(tv_sec: intervalNs / 1_000_000_000, tv_nsec: intervalNs % 1_000_000_000)
            _ = kevent64(kq, nil, 0, &ev, 1, 0, &ts)
        case .evfiltTimer, .evfiltTimerCritical, .evfiltTimerLeeway0, .evfiltTimerLeeway1us, .evfiltTimerLeeway50us:
            var fflags = UInt32(NOTE_NSECONDS)
            var ext: (UInt64, UInt64) = (0, 0)
            if mode == .evfiltTimerCritical { fflags |= UInt32(NOTE_CRITICAL) }
            if mode == .evfiltTimerLeeway0 { fflags |= UInt32(NOTE_LEEWAY); ext = (0, 0) }
            if mode == .evfiltTimerLeeway1us { fflags |= UInt32(NOTE_LEEWAY); ext = (0, 1_000) }
            if mode == .evfiltTimerLeeway50us { fflags |= UInt32(NOTE_LEEWAY); ext = (0, 50_000) }
            var change = kevent64_s(ident: 1, filter: Int16(EVFILT_TIMER), flags: UInt16(EV_ADD | EV_ONESHOT),
                                    fflags: fflags, data: Int64(intervalNs), udata: 0, ext: ext)
            _ = kevent64(kq, &change, 1, &ev, 1, 0, nil)
        }
        let late = Double(Int64(bitPattern: nowNs() &- target)) / 1000
        out.append(late)
    }
    return out
}

public func timerProbe(quick: Bool = false) -> Report {
    var rep = Report("Spike 3 — kqueue timer wake precision (lateness in µs vs. deadline)")
    let intervalsUs = quick ? [100, 1000, 2000] : [50, 100, 250, 500, 1000, 2000, 5000, 16_667]
    let qoses: [(String, qos_class_t)] = [("user-interactive", QOS_CLASS_USER_INTERACTIVE), ("default", QOS_CLASS_DEFAULT)]
    let only = ProcessInfo.processInfo.environment["TIMER_MODES"].map { Set($0.split(separator: ",").map(String.init)) }
    let modes: [TimerMode] = quick ? [.keventTimeout, .evfiltTimerCritical] : TimerMode.allCases
    let results = Mutex<[String]>([])
    for (qname, qos) in qoses {
        for mode in modes where only == nil || only!.contains("\(mode)") {
            onThread(qos: qos) {
                var lines = ["[\(qname)] \(mode.rawValue)"]
                for us in intervalsUs {
                    let samples = us >= 5000 ? (quick ? 30 : 120) : (quick ? 100 : 400)
                    let d = Distribution(timerLateness(mode: mode, intervalNs: us * 1000, samples: samples))
                    lines.append("    \(String(us).padding(toLength: 6, withPad: " ", startingAt: 0))µs: \(d.summary)")
                }
                results.withLock { $0.append(contentsOf: lines) }
            }
        }
    }
    results.withLock { for l in $0 { rep.add(l) } }

    // EVFILT_USER: another thread triggers; loop thread measures wake latency.
    for (qname, qos) in qoses {
        let kq = kqueue()
        var reg = kevent64_s(ident: 7, filter: Int16(EVFILT_USER), flags: UInt16(EV_ADD | EV_CLEAR), fflags: 0, data: 0, udata: 0, ext: (0, 0))
        _ = kevent64(kq, &reg, 1, nil, 0, 0, nil)
        let sent = Atomic<UInt64>(0)
        let finished = Atomic<Bool>(false)
        let samples = quick ? 200 : 1000
        let lat = Mutex<[Double]>([])
        let merged = Atomic<Int>(0)
        let loop = spawnThread(qos: qos) {
            var ev = kevent64_s()
            var got = [Double]()
            var timeout = timespec(tv_sec: 0, tv_nsec: 100_000_000)
            // EV_CLEAR coalesces triggers that land before the loop drains them, so a
            // wake is not 1:1 with a trigger: stop on the sender's done flag, not a count.
            while !finished.load(ordering: .acquiring) {
                guard kevent64(kq, nil, 0, &ev, 1, 0, &timeout) == 1 else { continue }
                got.append(Double(nowNs() &- sent.load(ordering: .acquiring)) / 1000)
            }
            merged.store(samples - got.count, ordering: .relaxed)
            lat.withLock { $0 = got }
        }
        onThread(qos: QOS_CLASS_USER_INITIATED) {
            for _ in 0..<samples {
                usleep(500)
                sent.store(nowNs(), ordering: .releasing)
                var trig = kevent64_s(ident: 7, filter: Int16(EVFILT_USER), flags: 0, fflags: UInt32(NOTE_TRIGGER), data: 0, udata: 0, ext: (0, 0))
                _ = kevent64(kq, &trig, 1, nil, 0, 0, nil)
            }
            finished.store(true, ordering: .releasing)
        }
        pthread_join(loop, nil)
        close(kq)
        rep.add("EVFILT_USER cross-thread wake [\(qname) loop]: \(Distribution(lat.withLock { $0 }).summary) µs (\(merged.load(ordering: .relaxed)) of \(samples) triggers coalesced)")
    }
    return rep
}
