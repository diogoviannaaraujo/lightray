import CryptoKit
import Darwin
import Foundation
import LightrayCore
import LightrayCrypto
import LightrayEngine
import LightrayRuntime
import LightrayTestSupport
import Synchronization

// lightray-poc: host, client and selftest over real UDP.
//
//   lightray-poc host   [--port 0] [--bitrate 20000000] [--fps 60]
//   lightray-poc client [--host 127.0.0.1] --port <port>
//   lightray-poc selftest [--seconds 12]
//
// `selftest` runs both roles in one process on 127.0.0.1 and drives the whole
// reconnect path — stream, park, blackout, resume on a new port — which is the
// manual check from the plan, automated.

// MARK: - Arguments

struct Arguments {
    var command: String
    var values: [String: String] = [:]

    init(_ raw: [String]) {
        command = raw.first ?? "selftest"
        var i = 1
        while i < raw.count {
            let key = raw[i]
            guard key.hasPrefix("--") else { i += 1; continue }
            let name = String(key.dropFirst(2))
            if i + 1 < raw.count, !raw[i + 1].hasPrefix("--") {
                values[name] = raw[i + 1]
                i += 2
            } else {
                values[name] = "true"
                i += 1
            }
        }
    }

    func int(_ name: String, _ fallback: Int) -> Int { values[name].flatMap(Int.init) ?? fallback }
    func string(_ name: String, _ fallback: String) -> String { values[name] ?? fallback }
    var flags: Set<String> { Set(values.keys) }
}

// The app supplies the pairing PSK; pairing UX is out of scope for v0.
let demoPSK = SymmetricKey(data: [UInt8](repeating: 0x5A, count: 32))
let demoPairingID: UInt64 = 0x1_1657_2A17

func demoStreams() -> [StreamDescriptor] {
    [
        StreamDescriptor(id: 1, kind: .video, direction: .hostToClient, streamClass: .media),
        StreamDescriptor(id: 2, kind: .audio, direction: .hostToClient, streamClass: .realtime),
        StreamDescriptor(id: 3, kind: .input, direction: .clientToHost, streamClass: .reliable),
    ]
}

func demoConfig(bitrate: Int, fps: Int) -> SessionConfig {
    var config = SessionConfig()
    config.bitrate = UInt32(bitrate)
    config.framerate = UInt16(fps)
    return config
}

/// Shared state the encoder loop and the event callback both touch.
final class AppState: @unchecked Sendable {
    private let lock = Mutex<Inner>(Inner())
    struct Inner {
        var refreshWanted: Set<UInt8> = []
        var sessions: Set<UInt32> = []
        var framesDelivered = 0
        var keyframesDelivered = 0
        var bytesDelivered = 0
        var lastEvent = "-"
        var parked = false
        var resumeAt: Instant?
        var lastResumeLatencyMillis: Double?
    }

    func with<T>(_ body: (inout Inner) -> T) -> T { lock.withLock { body(&$0) } }
    func read<T>(_ body: (Inner) -> T) -> T { lock.withLock { body($0) } }

    func takeRefreshRequests() -> Set<UInt8> {
        lock.withLock { state in
            let wanted = state.refreshWanted
            state.refreshWanted.removeAll()
            return wanted
        }
    }
}

func describe(_ event: ConnectionEvent) -> String {
    switch event {
    case .established(let id, _, _): return "established(session \(id))"
    case .frameReceived: return "frameReceived"
    case .frameGap(let s, let f): return "frameGap(stream \(s), frame \(f))"
    case .frameUndecodable(let s, let f): return "frameUndecodable(stream \(s), frame \(f))"
    case .datagramReceived: return "datagramReceived"
    case .reliableMessage: return "reliableMessage"
    case .refreshRequired(let s, let p, let c):
        return "refreshRequired(stream \(s), \(p), \(c.count) LTR candidates)"
    case .parked: return "parked"
    case .pipelineIdle: return "pipelineIdle"
    case .resumed: return "resumed"
    case .expired: return "expired"
    case .rebound: return "rebound"
    case .sessionLost: return "sessionLost"
    case .bitrateChanged(let bps, let reason): return "bitrateChanged(\(bps / 1_000_000) Mbps, \(reason))"
    case .configurationChanged: return "configurationChanged"
    case .reconfigureResult(let id, _, let mask):
        return "reconfigureResult(req \(id), rejected 0x\(String(mask, radix: 16)))"
    case .closed(let code): return "closed(\(code))"
    }
}

func formatStats(_ snapshot: StatsSnapshot, prefix: String) -> String {
    let path = snapshot.path
    let quality = snapshot.linkQuality
    let stream = snapshot.streams[1] ?? StreamStats()
    return String(
        format: "%@ %-12@ rtt %5.1f ms  queue %5.1f ms  loss %5.2f%%  %6llu sent / %6llu recv  "
              + "nack %4llu  rtx %4llu  frames %5llu  key %3llu  p50 %5.1f ms  %@%@",
        prefix as NSString, snapshot.state as NSString,
        Double(path.rtt.smoothed.nanos) / 1e6,
        Double(path.queuingDelay.nanos) / 1e6,
        path.reportedLoss * 100,
        path.packetsSent, path.packetsReceived,
        path.nacksSent + path.nacksReceived, path.retransmitsSent,
        stream.framesDelivered, stream.keyframesDelivered,
        Double(stream.completionLatency.quantile(0.5)) / 1000,
        quality.grade.rawValue as NSString,
        snapshot.backstopEngaged ? " BACKSTOP" as NSString : "" as NSString)
}

// MARK: - Host

func runHost(_ arguments: Arguments) throws {
    let state = AppState()
    let config = demoConfig(bitrate: arguments.int("bitrate", 20_000_000),
                            fps: arguments.int("fps", 60))
    var engine = EngineConfig()
    // Short windows so a manual park/resume test does not take an hour.
    engine.parkAfterSilence = .seconds(2)
    engine.pipelineIdleAfter = .seconds(30)
    engine.graceWindow = .seconds(10 * 60)

    let host = try LightrayHost(psk: demoPSK, streams: demoStreams(), config: config,
                                engine: engine, port: UInt16(arguments.int("port", 0)),
                                onEvent: { event in
        state.with { s in
            s.lastEvent = "session \(event.sessionID): \(describe(event.event))"
            switch event.event {
            case .established: s.sessions.insert(event.sessionID)
            case .expired, .closed: s.sessions.remove(event.sessionID)
            case .refreshRequired(let stream, _, _): s.refreshWanted.insert(stream)
            case .parked: s.parked = true
            case .resumed: s.parked = false
            default: break
            }
        }
        if case .refreshRequired = event.event {} else {
            print("  [host] \(describe(event.event)) (session \(event.sessionID))")
        }
    })
    host.start()
    defer { host.stop() }

    print("lightray-poc host listening on port \(host.localPort)")
    print("  run: lightray-poc client --port \(host.localPort)")
    print("  \(config.width)x\(config.height) @ \(config.framerate) fps, \(config.bitrate / 1_000_000) Mbps, HEVC + Opus pinned by wire v0")

    var video = SyntheticFrameSource(stream: 1, bitrate: config.bitrate,
                                     framerate: config.framerate, idrInterval: 0)
    // Opus packets stand alone, so the audio source marks its frames independent.
    var audio = SyntheticFrameSource(stream: 2, bitrate: 128_000, framerate: 50,
                                     independentFrames: true)
    let frameInterval = Double(config.frameInterval.nanos) / 1e9
    var nextFrame = Date()
    var nextAudio = Date()
    var nextPrint = Date().addingTimeInterval(1)

    while true {
        let now = Date()
        let hasSession = state.read { !$0.sessions.isEmpty }
        let parked = state.read { $0.parked }

        if hasSession, !parked, now >= nextFrame {
            // An app's encoder loop: one frame per interval, forcing a keyframe
            // whenever the protocol has asked for one.
            let forced = state.takeRefreshRequests().contains(1)
            host.submit(video.next(at: SystemClock.shared.now(), forceIDR: forced))
            nextFrame = now.addingTimeInterval(frameInterval)
        }
        if hasSession, !parked, now >= nextAudio {
            host.submit(audio.next(at: SystemClock.shared.now()))
            nextAudio = now.addingTimeInterval(0.02)     // Opus 20 ms frames
        }
        if now >= nextPrint {
            nextPrint = now.addingTimeInterval(1)
            let snapshots = host.snapshots()
            if snapshots.isEmpty {
                print("[host] waiting for a client on port \(host.localPort)")
            } else {
                for (id, snapshot) in snapshots.sorted(by: { $0.key < $1.key }) {
                    print(formatStats(snapshot, prefix: "[host \(id)]"))
                }
            }
        }
        usleep(1_000)
    }
}

// MARK: - Client

func runClient(_ arguments: Arguments) throws {
    let port = UInt16(arguments.int("port", 0))
    guard port != 0 else {
        print("usage: lightray-poc client --port <port> [--host 127.0.0.1]")
        exit(2)
    }
    let state = AppState()
    let config = demoConfig(bitrate: arguments.int("bitrate", 20_000_000),
                            fps: arguments.int("fps", 60))
    var engine = EngineConfig()
    engine.parkAfterSilence = .seconds(2)

    let client = try LightrayClient(psk: demoPSK, pairingID: demoPairingID, streams: demoStreams(),
                                    config: config, engine: engine, onEvent: { event in
        state.with { s in
            s.lastEvent = describe(event)
            switch event {
            case .frameReceived(let frame):
                s.framesDelivered += 1
                s.bytesDelivered += frame.payload.count
                if frame.isKeyframe {
                    s.keyframesDelivered += 1
                    if let started = s.resumeAt {
                        s.lastResumeLatencyMillis = Double((SystemClock.shared.now() - started).nanos) / 1e6
                        s.resumeAt = nil
                    }
                }
            case .parked: s.parked = true
            case .resumed: s.parked = false
            default: break
            }
        }
        switch event {
        case .frameReceived: break
        default: print("  [client] \(describe(event))")
        }
    })
    client.start()
    defer { client.stop() }

    let target = arguments.string("host", "127.0.0.1")
    print("lightray-poc client -> \(target):\(port) from source port \(client.localPort)")
    print("  type: p = park, r = resume, d = resume with decoder_lost, b = bitrate 5 Mbps, q = quit")
    client.connect(host: target, port: port)

    // Commands arrive on their own thread so the stats keep printing.
    let commands = Mutex<[String]>([])
    let reader = Thread {
        while let line = readLine(strippingNewline: true) {
            commands.withLock { $0.append(line) }
        }
    }
    reader.start()

    var nextPrint = Date().addingTimeInterval(1)
    var sequence = 0
    var nextInput = Date()
    while true {
        for command in commands.withLock({ list -> [String] in
            let copy = list
            list.removeAll()
            return copy
        }) {
            switch command.trimmingCharacters(in: .whitespaces) {
            case "p":
                print("  [client] park()")
                client.park()
            case "r":
                print("  [client] resume() — new socket, RESUME until STATE")
                state.with { $0.resumeAt = SystemClock.shared.now() }
                client.resume(decoderLost: false)
            case "d":
                print("  [client] resume(decoderLost: true) — the recovery IDR rebuilds the decoder")
                state.with { $0.resumeAt = SystemClock.shared.now() }
                client.resume(decoderLost: true)
            case "b":
                print("  [client] RECONFIGURE to 5 Mbps")
                var body = ControlBody(message: .reconfigure)
                body.bitrate = 5_000_000
                client.reconfigure(body)
            case "q":
                client.close()
                usleep(200_000)
                return
            default:
                print("  [client] unknown command '\(command)'")
            }
        }

        // A trickle of reliable input, the reverse direction.
        let now = Date()
        if client.phase == .connected, now >= nextInput {
            sequence += 1
            client.sendReliable([UInt8(truncatingIfNeeded: sequence), 0x01], stream: 3)
            nextInput = now.addingTimeInterval(0.05)
        }
        if now >= nextPrint {
            nextPrint = now.addingTimeInterval(1)
            let snapshot = client.snapshot()
            var line = formatStats(snapshot, prefix: "[client]")
            if let latency = state.read({ $0.lastResumeLatencyMillis }) {
                line += String(format: "  resume->IDR %.0f ms", latency)
            }
            print(line + "  port \(client.localPort)")
        }
        usleep(1_000)
    }
}

// MARK: - Selftest

/// Both roles in one process: stream, park, blackout, resume on a new port.
func runSelftest(_ arguments: Arguments) throws {
    let seconds = Double(arguments.int("seconds", 12))
    let config = demoConfig(bitrate: arguments.int("bitrate", 20_000_000),
                            fps: arguments.int("fps", 60))
    var engine = EngineConfig()
    engine.parkAfterSilence = .seconds(2)
    engine.pipelineIdleAfter = .seconds(30)
    engine.graceWindow = .seconds(600)

    let hostState = AppState()
    let clientState = AppState()

    let host = try LightrayHost(psk: demoPSK, streams: demoStreams(), config: config,
                                engine: engine, onEvent: { event in
        hostState.with { s in
            switch event.event {
            case .established: s.sessions.insert(event.sessionID)
            case .expired, .closed: s.sessions.remove(event.sessionID)
            case .refreshRequired(let stream, _, _): s.refreshWanted.insert(stream)
            case .parked: s.parked = true
            case .resumed: s.parked = false
            default: break
            }
        }
        switch event.event {
        case .frameReceived, .refreshRequired: break
        default: print("  [host] \(describe(event.event))")
        }
    })
    let client = try LightrayClient(psk: demoPSK, pairingID: demoPairingID, streams: demoStreams(),
                                    config: config, engine: engine, onEvent: { event in
        clientState.with { s in
            switch event {
            case .frameReceived(let frame):
                s.framesDelivered += 1
                s.bytesDelivered += frame.payload.count
                if frame.isKeyframe {
                    s.keyframesDelivered += 1
                    if let started = s.resumeAt {
                        s.lastResumeLatencyMillis = Double((SystemClock.shared.now() - started).nanos) / 1e6
                        s.resumeAt = nil
                    }
                }
            case .parked: s.parked = true
            case .resumed: s.parked = false
            default: break
            }
        }
        switch event {
        case .frameReceived: break
        default: print("  [client] \(describe(event))")
        }
    })
    host.start(); client.start()
    defer { client.stop(); host.stop() }

    print("lightray-poc selftest: host port \(host.localPort), client port \(client.localPort)")
    client.connect(host: "127.0.0.1", port: host.localPort)

    var video = SyntheticFrameSource(stream: 1, bitrate: config.bitrate, framerate: config.framerate)
    var audio = SyntheticFrameSource(stream: 2, bitrate: 128_000, framerate: 50,
                                     independentFrames: true)
    let frameInterval = Double(config.frameInterval.nanos) / 1e9
    let start = Date()
    var nextFrame = start
    var nextAudio = start
    var nextPrint = start.addingTimeInterval(1)

    // The script: stream, park, wait, resume, stream again.
    let parkAt = start.addingTimeInterval(seconds * 0.35)
    let resumeAt = start.addingTimeInterval(seconds * 0.6)
    var parked = false
    var resumed = false

    while Date().timeIntervalSince(start) < seconds {
        let now = Date()
        if !parked, now >= parkAt {
            parked = true
            print("  -- park() --")
            client.park()
        }
        if parked, !resumed, now >= resumeAt {
            resumed = true
            print("  -- resume() on a fresh socket --")
            clientState.with { $0.resumeAt = SystemClock.shared.now() }
            client.resume(decoderLost: false)
        }

        let hasSession = hostState.read { !$0.sessions.isEmpty }
        let hostParked = hostState.read { $0.parked }
        if hasSession, !hostParked, now >= nextFrame {
            let forced = hostState.takeRefreshRequests().contains(1)
            host.submit(video.next(at: SystemClock.shared.now(), forceIDR: forced))
            nextFrame = now.addingTimeInterval(frameInterval)
        }
        if hasSession, !hostParked, now >= nextAudio {
            host.submit(audio.next(at: SystemClock.shared.now()))
            nextAudio = now.addingTimeInterval(0.02)
        }
        if now >= nextPrint {
            nextPrint = now.addingTimeInterval(1)
            print(formatStats(client.snapshot(), prefix: "[client]") + "  port \(client.localPort)")
        }
        usleep(500)
    }

    let summary = clientState.read { $0 }
    let snapshot = client.snapshot()
    let loop = client.loopStats
    print("")
    print("selftest summary over \(Int(seconds)) s")
    print("  frames delivered      \(summary.framesDelivered)")
    print("  keyframes delivered   \(summary.keyframesDelivered) (one at the start, one per resume)")
    print(String(format: "  bytes delivered       %.1f MB", Double(summary.bytesDelivered) / 1e6))
    print(String(format: "  srtt                  %.2f ms", Double(snapshot.path.rtt.smoothed.nanos) / 1e6))
    print("  NACKs sent            \(snapshot.path.nacksSent)")
    print("  retransmits received  \(snapshot.path.retransmitsSent)")
    // Rebinding is something the host does, so the count lives on its side.
    let hostSnapshots = host.snapshots()
    let rebinds = hostSnapshots.values.map(\.path.rebinds).reduce(0, +)
    let parks = hostSnapshots.values.map(\.reconnect.parks).reduce(0, +)
    let resumes = hostSnapshots.values.map(\.reconnect.resumes).reduce(0, +)
    print("  host rebinds          \(rebinds) (the resume arrived on a new source port)")
    print("  host parks / resumes  \(parks) / \(resumes)")
    if let latency = summary.lastResumeLatencyMillis {
        print(String(format: "  resume -> first IDR   %.0f ms", latency))
    }
    print("  client loop           \(loop.iterations) turns, \(loop.sent) sent, \(loop.received) received, \(loop.sendErrors) errors")
    // Per-datagram CPU on a mostly idle loop is dominated by the fixed cost of
    // waking up, so report the share of a core as well.
    print(String(format: "  client loop CPU       %.0f ms total, %.1f%% of one core, %.2f µs per loop turn",
                 Double(loop.cpuNanos) / 1e6,
                 Double(loop.cpuNanos) / (seconds * 1e9) * 100,
                 Double(loop.cpuNanos) / Double(max(loop.iterations, 1)) / 1000))
    let phases = client.loopCPUBreakdown
    let turns = Double(max(loop.iterations, 1))
    print(String(format: "    by phase per turn   wait %.1f  receive %.1f  timers %.1f  transmit %.1f  publish %.1f µs",
                 Double(phases.wait) / turns / 1000,
                 Double(phases.receive) / turns / 1000,
                 Double(phases.timers) / turns / 1000,
                 Double(phases.transmit) / turns / 1000,
                 Double(phases.publish) / turns / 1000))
    print("  timeline:")
    for event in snapshot.timeline.suffix(12) {
        print("    \(event.kind.rawValue)\(event.detail == 0 ? "" : " (\(event.detail))")")
    }

    if summary.framesDelivered == 0 || summary.keyframesDelivered < 2 {
        print("\nselftest FAILED: expected frames and at least two keyframes (start plus resume)")
        exit(1)
    }
    print("\nselftest OK")
}

// MARK: - Entry

let arguments = Arguments(Array(CommandLine.arguments.dropFirst()))
do {
    switch arguments.command {
    case "host": try runHost(arguments)
    case "client": try runClient(arguments)
    case "selftest": try runSelftest(arguments)
    default:
        print("""
        usage:
          lightray-poc host     [--port 0] [--bitrate 20000000] [--fps 60]
          lightray-poc client   --port <port> [--host 127.0.0.1]
          lightray-poc selftest [--seconds 12]
        """)
        exit(2)
    }
} catch {
    print("error: \(error)")
    exit(1)
}
