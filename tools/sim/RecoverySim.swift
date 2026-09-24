// RecoverySim: Monte-Carlo comparison of video loss-recovery strategies for Lightray.
// Build: swiftc -O -parse-as-library RecoverySim.swift -o recoverysim
//
// Model (deliberately simple, stated so the numbers can be challenged):
// - 60 fps; each frame is split into 1149-byte fragments (Lightray v0 stride at 1200 B datagrams).
// - Sender paces each frame at max(1.25 x bitrate, frame_bytes / frame_interval); frames queue FIFO.
// - Loss is a time-based Gilbert-Elliott channel: exponential good/bad periods with a loss probability
//   in each. Retransmissions go through the same channel at the time they are sent.
// - Optional AWDL-style pauses: every ~1 s the radio leaves the channel for 30-50 ms; packets that
//   would arrive then are delivered at the end of the pause (delay, not loss).
// - Receiver decodes in order. A frame not decodable within 3 frame intervals of its loss-free
//   completion time is abandoned (v0 deadline), which triggers a recovery request; the next frame
//   the host encodes after the request arrives is a recovery frame (LTR refresh, 0.8 x IDR size).
//   Frames in between are undecodable. A lost recovery frame triggers another request.
// - Congestion and queueing are NOT modelled: this isolates loss recovery from rate control.
import Foundation

struct Rng {
    var s: UInt64
    mutating func next() -> UInt64 { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return s }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func exp(_ mean: Double) -> Double { -mean * log(max(1e-12, unit())) }
    mutating func logNormal(mean: Double, cv: Double) -> Double {
        let s2 = log(1 + cv * cv), mu = log(mean) - s2 / 2
        let u1 = max(1e-12, unit()), u2 = unit()
        let z = sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
        return Foundation.exp(mu + sqrt(s2) * z)
    }
}

struct Scenario {
    var name: String
    var rttMs: Double
    var mbps: Double
    var content: Content
    var goodLoss: Double          // loss probability outside bursts
    var burstMs: Double           // mean burst duration
    var burstEveryMs: Double      // mean time between bursts
    var burstLoss: Double         // loss probability inside a burst
    var awdl: Bool
    var idrKB: Double
    var deadlineMs: Double = 0     // 0 = three frame intervals (v0 default)
    enum Content { case game, desktop }
}

struct Strategy {
    var name: String
    var fec: Double               // parity / data ratio
    var minParity: Int
    var nack: Nack
    var speculative: Bool         // Moonlight-style early loss declaration when losses exceed parity
    enum Nack { case none, eager, residual }
}

struct Channel {
    var bad: [(Double, Double)] = []   // sorted [start, end) bad intervals, ms
    var pauses: [(Double, Double)] = []
    init(_ sc: Scenario, durationMs: Double, rng: inout Rng) {
        var t = rng.exp(sc.burstEveryMs)
        while t < durationMs + 2000 {
            let d = rng.exp(sc.burstMs)
            bad.append((t, t + d))
            t += d + rng.exp(sc.burstEveryMs)
        }
        if sc.awdl {
            var p = 300.0
            while p < durationMs + 2000 {
                let d = 30 + rng.unit() * 20
                pauses.append((p, p + d))
                p += 1000 + (rng.unit() - 0.5) * 200
            }
        }
    }
    private func find(_ arr: [(Double, Double)], _ t: Double) -> (Double, Double)? {
        var lo = 0, hi = arr.count
        while lo < hi { let mid = (lo + hi) / 2; if arr[mid].1 <= t { lo = mid + 1 } else { hi = mid } }
        if lo < arr.count, arr[lo].0 <= t, t < arr[lo].1 { return arr[lo] }
        return nil
    }
    func lost(at t: Double, _ sc: Scenario, _ rng: inout Rng) -> Bool {
        let p = find(bad, t) != nil ? sc.burstLoss : sc.goodLoss
        return rng.unit() < p
    }
    func deliver(_ t: Double) -> Double { if let w = find(pauses, t) { return w.1 } else { return t } }
}

struct Result {
    var frames = 0, dataPkts = 0, extraPkts = 0
    var hitches = 0, freezes = 0
    var freezeMs = 0.0
    var lateness: [Double] = []
    var lostFrames = 0
}

let payload = 1149.0
let wire = 1200.0

func simulate(_ sc: Scenario, _ st: Strategy, minutes: Double, seed: UInt64) -> Result {
    var rng = Rng(s: seed &* 2654435761 &+ 1)
    let T = 1000.0 / 60.0
    let D = sc.deadlineMs > 0 ? sc.deadlineMs : 3 * T
    let owd = sc.rttMs / 2
    let reorder = max(1.0, sc.rttMs / 4)
    let nackRetry = max(1.5 * sc.rttMs, 2.0)
    let encodeMs = 7.0
    let durationMs = minutes * 60_000
    let n = Int(durationMs / T)
    let ch = Channel(sc, durationMs: durationMs, rng: &rng)
    let meanFrame = sc.mbps * 1e6 / 8 / 60
    let paceFloor = 1.25 * sc.mbps * 1e6 / 8 / 1000   // bytes per ms

    var r = Result()
    var senderFree = 0.0
    var lastDisplay = 0.0
    var waitingSince: Double? = nil      // loss-free time of the frame whose loss started a freeze
    var recoveryAt: Double? = nil        // host time at which the recovery request arrives
    var nextSlotIsRecovery = false

    for i in 0..<n {
        let slot = Double(i) * T
        // Does the host produce a recovery frame in this slot?
        if let ra = recoveryAt, slot >= ra { nextSlotIsRecovery = true; recoveryAt = nil }
        let isRecovery = nextSlotIsRecovery
        nextSlotIsRecovery = false
        var bytes: Double
        if isRecovery {
            bytes = 0.8 * sc.idrKB * 1024
        } else {
            switch sc.content {
            case .game: bytes = rng.logNormal(mean: meanFrame, cv: 0.35)
            case .desktop: bytes = rng.logNormal(mean: meanFrame * 0.35, cv: 1.6)
            }
        }
        bytes = max(200, bytes)
        let k = Int((bytes / payload).rounded(.up))
        var m = 0
        if st.fec > 0 { m = max(Int((Double(k) * st.fec).rounded(.up)), st.minParity) }
        let total = k + m
        let pace = max(paceFloor, Double(total) * wire / T)
        let gap = wire / pace
        let start = max(slot + encodeMs, senderFree)
        senderFree = start + Double(total) * gap
        r.frames += 1
        r.dataPkts += k
        r.extraPkts += m

        // Original transmissions.
        var arrivals: [Double] = []           // arrival times of useful packets (data or parity)
        var lostData: [Int] = []
        var lostCount = 0
        var specDeclare: Double? = nil
        var lastArrivalSeen = start
        var dataArrivals = [Double](repeating: .infinity, count: k)
        var lastIndexReceived = false
        for j in 0..<total {
            let ts = start + Double(j) * gap
            if ch.lost(at: ts, sc, &rng) {
                lostCount += 1
                if j < k { lostData.append(j) }
                if st.speculative && st.nack == .none && lostCount > m && specDeclare == nil {
                    // Known unrecoverable once a later packet shows the (m+1)-th hole.
                    specDeclare = ch.deliver(ts + gap + owd) + reorder
                }
            } else {
                let a = ch.deliver(ts + owd)
                arrivals.append(a)
                if j < k { dataArrivals[j] = a }
                if j == total - 1 { lastIndexReceived = true }
                lastArrivalSeen = max(lastArrivalSeen, a)
            }
        }
        let baseline = start + Double(k - 1) * gap + owd
        let deadline = baseline + D
        let nextFrameFirstArrival = ch.deliver(max(slot + T + encodeMs, senderFree) + owd)

        // Retransmission (NACK) machinery: returns arrival time of a repaired packet or infinity.
        func repair(firstDetect: Double) -> Double {
            var detect = firstDetect
            while detect < deadline {
                let sendAt = detect + owd
                let arrive = ch.deliver(sendAt + owd)
                r.extraPkts += 1
                if !ch.lost(at: sendAt, sc, &rng) { return arrive }
                detect += nackRetry
            }
            return .infinity
        }

        if st.nack == .eager && !lostData.isEmpty {
            for j in lostData {
                // Hole noticed when the next packet after j arrives (or the next frame starts).
                var detect = nextFrameFirstArrival
                for jj in (j + 1)..<total {
                    let ts = start + Double(jj) * gap
                    let a = ch.deliver(ts + owd)
                    if jj < k ? dataArrivals[jj].isFinite : true { detect = a; break }
                }
                let a = repair(firstDetect: detect + reorder)
                if a.isFinite { arrivals.append(a); dataArrivals[j] = a }
            }
        } else if st.nack == .residual {
            let have = arrivals.count
            if have < k {
                // After the frame's packets have all been sent, ask only for what FEC cannot cover.
                let lastIdx = ch.deliver(start + Double(total - 1) * gap + owd)
                let detect = (lastIndexReceived ? min(lastIdx, nextFrameFirstArrival) : nextFrameFirstArrival) + reorder
                if st.speculative && detect + sc.rttMs > deadline && specDeclare == nil { specDeclare = detect }
                for _ in 0..<(k - have) {
                    let a = repair(firstDetect: detect)
                    if a.isFinite { arrivals.append(a) }
                }
            }
        }

        // When is the frame decodable?
        var complete = Double.infinity
        if st.fec > 0 {
            if arrivals.count >= k { arrivals.sort(); complete = arrivals[k - 1] }
        } else {
            let mx = dataArrivals.max() ?? .infinity
            complete = mx
        }
        if complete > deadline { complete = .infinity }

        if waitingSince != nil {
            // Stream is frozen: only a recovery frame can end it.
            if isRecovery {
                if complete.isFinite {
                    let shown = max(complete, lastDisplay)
                    r.freezeMs += shown - waitingSince!
                    lastDisplay = shown
                    waitingSince = nil
                } else {
                    r.lostFrames += 1
                    recoveryAt = deadline + owd   // lost recovery frame: ask again
                }
            }
            continue
        }
        if complete.isFinite {
            let shown = max(complete, lastDisplay)
            let late = shown - baseline
            r.lateness.append(late)
            if late > T { r.hitches += 1 }
            lastDisplay = shown
        } else {
            r.lostFrames += 1
            r.freezes += 1
            waitingSince = baseline
            let declare = min(specDeclare ?? deadline, deadline)
            recoveryAt = declare + owd
        }
    }
    return r
}

func pct(_ xs: [Double], _ p: Double) -> Double {
    guard !xs.isEmpty else { return .nan }
    let s = xs.sorted()
    return s[min(s.count - 1, Int(p / 100 * Double(s.count - 1)))]
}

@main struct Main {
    static func main() {
        let minutes = Double(CommandLine.arguments.dropFirst().first ?? "20") ?? 20
        var scenarios: [Scenario] = [
            Scenario(name: "LAN game, good Wi-Fi (RTT 4 ms, 50 Mb/s)", rttMs: 4, mbps: 50, content: .game,
                     goodLoss: 0.0002, burstMs: 3, burstEveryMs: 2000, burstLoss: 0.7, awdl: false, idrKB: 250),
            Scenario(name: "LAN game, busy Wi-Fi (RTT 6 ms, 50 Mb/s)", rttMs: 6, mbps: 50, content: .game,
                     goodLoss: 0.001, burstMs: 8, burstEveryMs: 500, burstLoss: 0.8, awdl: false, idrKB: 250),
            Scenario(name: "LAN game, good Wi-Fi + AWDL pauses (Apple client)", rttMs: 4, mbps: 50, content: .game,
                     goodLoss: 0.0002, burstMs: 3, burstEveryMs: 2000, burstLoss: 0.7, awdl: true, idrKB: 250),
            Scenario(name: "WAN desktop, fixed line (RTT 30 ms, 20 Mb/s)", rttMs: 30, mbps: 20, content: .desktop,
                     goodLoss: 0.001, burstMs: 5, burstEveryMs: 5000, burstLoss: 0.5, awdl: false, idrKB: 142),
            Scenario(name: "WAN iPad, cellular (RTT 60 ms, 10 Mb/s)", rttMs: 60, mbps: 10, content: .desktop,
                     goodLoss: 0.005, burstMs: 20, burstEveryMs: 1000, burstLoss: 0.5, awdl: false, idrKB: 102),
            Scenario(name: "WAN bad (RTT 100 ms, 10 Mb/s)", rttMs: 100, mbps: 10, content: .desktop,
                     goodLoss: 0.01, burstMs: 30, burstEveryMs: 500, burstLoss: 0.6, awdl: false, idrKB: 102),
        ]
        // Desktop latency budget: allow one retransmission round trip on top of the frame deadline.
        for base in scenarios where base.content == .desktop {
            var v = base
            v.deadlineMs = max(50, 2 * base.rttMs + 20)
            v.name = base.name + String(format: ", budget %.0f ms", v.deadlineMs)
            scenarios.append(v)
        }
        let strategies: [Strategy] = [
            Strategy(name: "Recovery frame only (LTR/RFI)", fec: 0, minParity: 0, nack: .none, speculative: false),
            Strategy(name: "v0: NACK first", fec: 0, minParity: 0, nack: .eager, speculative: false),
            Strategy(name: "Moonlight: FEC 20% min 2 + spec. RFI", fec: 0.20, minParity: 2, nack: .none, speculative: true),
            Strategy(name: "Hybrid: FEC 10% min 1 + NACK + spec.", fec: 0.10, minParity: 1, nack: .residual, speculative: true),
            Strategy(name: "Hybrid: FEC 20% min 2 + NACK + spec.", fec: 0.20, minParity: 2, nack: .residual, speculative: true),
            Strategy(name: "Hybrid: FEC 40% min 2 + NACK + spec.", fec: 0.40, minParity: 2, nack: .residual, speculative: true),
        ]
        print("# Recovery simulation, \(Int(minutes)) simulated minutes per cell, 60 fps, deadline 3 frames unless stated")
        for sc in scenarios {
            // Measure the realised loss rate of the channel once.
            var rng = Rng(s: 99)
            let ch = Channel(sc, durationMs: 600_000, rng: &rng)
            var lost = 0
            let samples = 200_000
            for s in 0..<samples { if ch.lost(at: Double(s) * 3.0, sc, &rng) { lost += 1 } }
            print("\n## \(sc.name) — realised packet loss \(String(format: "%.2f", 100 * Double(lost) / Double(samples)))%\(sc.awdl ? ", AWDL pauses 30-50 ms/s" : "")")
            print("strategy                              overhead  late>1f/min  freezes/min  freeze ms/min  mean freeze ms  p50 late  p99 late")
            for st in strategies {
                let res = simulate(sc, st, minutes: minutes, seed: 7)
                let ov = 100 * Double(res.extraPkts) / Double(res.dataPkts)
                let mf = res.freezes > 0 ? res.freezeMs / Double(res.freezes) : 0
                print(String(format: "%-37@ %7.1f%%  %11.1f  %11.2f  %13.0f  %14.0f  %7.1f  %8.1f",
                             st.name as NSString, ov, Double(res.hitches) / minutes, Double(res.freezes) / minutes,
                             res.freezeMs / minutes, mf, pct(res.lateness, 50), pct(res.lateness, 99)))
            }
        }
    }
}
