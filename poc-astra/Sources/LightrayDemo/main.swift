import Foundation
import Lightray
import LightrayTestSupport
import Synchronization

struct Options {
    let arguments: [String]
    func value(_ name: String, default fallback: String) -> String {
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return fallback }
        return arguments[index + 1]
    }
    func integer(_ name: String, default fallback: Int, range: ClosedRange<Int>) throws -> Int {
        guard let value = Int(value(name, default: String(fallback))), range.contains(value) else { throw DemoError.usage("Invalid \(name)") }
        return value
    }
}
enum DemoError: Error {
    case usage(String)
    case timeout
    case runtime(String)
}
struct Observation {
    var session: UInt32?
    var frames = 0
    var bytes: UInt64 = 0
    var latencies: [UInt64] = []
    var refresh = true
    var errors: [String] = []
    var parks = 0, resumes = 0
}
let demoPSK = [UInt8](repeating: 0x4c, count: 32)
let demoHostKey = [UInt8](repeating: 0x72, count: 32)

func runLoopback(options: Options) throws {
    let seconds = try options.integer("--seconds", default: 5, range: 1...120)
    let mbps = try options.integer("--mbps", default: 20, range: 1...1000)
    let reconnect = options.arguments.contains("--reconnect")
    let observation = Mutex(Observation())
    let host = try LightrayHost(port: 0, pairings: [1: demoPSK], secret: demoHostKey) { id, event in
        observation.withLock { state in
            switch event {
            case .connected: state.session = id
            case .refreshRequired: state.refresh = true
            case .parked: state.parks += 1
            case .resumed: state.resumes += 1
            case .error(let error): state.errors.append(error)
            default: break
            }
        }
    }
    var configuration = Configuration()
    configuration.bitrate = UInt32(mbps * 1_000_000)
    configuration.bitrateFloor = min(5_000_000, configuration.bitrate)
    let client = try LightrayClient(peer: .init(host: "127.0.0.1", port: host.port), pairingID: 1, psk: demoPSK, configuration: configuration, monitorPath: false) { _, event in
        switch event {
        case .frame(let frame, let info):
            let now = SuspendingClock().now().microseconds
            observation.withLock {
                $0.frames += 1
                $0.bytes += UInt64(frame.count)
                $0.latencies.append(UInt64(now &- info.captureTime) * 1000)
            }
        case .error(let error): observation.withLock { $0.errors.append(error) }
        default: break
        }
    }
    defer {
        client.stop()
        host.stop()
    }
    let clock = SuspendingClock()
    let deadline = clock.now().advanced(by: 3_000_000_000)
    while observation.withLock({ $0.session == nil }) {
        guard clock.now() < deadline else { throw DemoError.timeout }
        Thread.sleep(forTimeInterval: 0.001)
    }
    let id = observation.withLock { $0.session! }
    let oldPort = client.localPort
    let frameSize = mbps * 1_000_000 / 8 / 60
    let frameBytes = SyntheticFrames.bytes(count: frameSize)
    let started = clock.now()
    var submitted = 0
    for frame in 0..<(seconds * 60) {
        let due = started.advanced(by: UInt64(frame) * 1_000_000_000 / 60)
        let now = clock.now()
        if due > now { Thread.sleep(forTimeInterval: Double(due.elapsed(since: now)) / 1e9) }
        if reconnect, frame == seconds * 30 {
            client.park()
            Thread.sleep(forTimeInterval: 0.03)
            client.resume()
            Thread.sleep(forTimeInterval: 0.03)
        }
        let idr = observation.withLock {
            let value = $0.refresh
            $0.refresh = false
            return value
        }
        host.submit(sessionID: id, bytes: frameBytes, info: SyntheticFrames.info(idr: idr, captureTime: clock.now().microseconds))
        submitted += 1
    }
    let finishedSending = clock.now()
    let drainDeadline = finishedSending.advanced(by: 2_000_000_000)
    while observation.withLock({ $0.frames < submitted }), clock.now() < drainDeadline { Thread.sleep(forTimeInterval: 0.001) }
    let finished = clock.now()
    let result = observation.withLock { $0 }
    let latencies = result.latencies.sorted()
    let elapsed = Double(finished.elapsed(since: started)) / 1e9
    func percentile(_ p: Double) -> Double { latencies.isEmpty ? 0 : Double(latencies[min(latencies.count - 1, Int(Double(latencies.count - 1) * p))]) / 1e6 }
    let report: [String: Any] = ["benchmark": "macOS UDP loopback, AES-GCM, full session", "target_mbps": mbps, "seconds": seconds, "elapsed_seconds_including_drain": elapsed, "frames_submitted": submitted, "frames_received": result.frames, "udp_received_gbps_including_drain": Double(client.stats.path.bytesReceived) * 8 / elapsed / 1e9, "delivered_mbps_including_drain": Double(result.bytes) * 8 / elapsed / 1e6, "latency_p50_ms": percentile(0.5), "latency_p99_ms": percentile(0.99), "nacks": client.stats.streams.nacks, "retransmits": host.stats.streams.retransmits, "authentication_failures": client.stats.path.authenticationFailures, "old_client_port": oldPort, "new_client_port": client.localPort, "parks": result.parks, "resumes": result.resumes, "errors": result.errors]
    print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
    if !result.errors.isEmpty { throw DemoError.runtime(result.errors.joined(separator: "; ")) }
    if result.frames == 0 { throw DemoError.timeout }
}

func runHost(options: Options) throws {
    let port = UInt16(try options.integer("--port", default: 47000, range: 1...65535))
    let seconds = try options.integer("--seconds", default: 60, range: 1...3600)
    let state = Mutex(Observation())
    let host = try LightrayHost(port: port, pairings: [1: demoPSK], secret: demoHostKey) { id, event in
        state.withLock { value in
            switch event {
            case .connected:
                value.session = id
                print("connected session=\(id)")
            case .refreshRequired: value.refresh = true
            case .parked: print("parked session=\(id)")
            case .resumed: print("resumed session=\(id)")
            case .error(let error): print("error: \(error)")
            default: break
            }
        }
    }
    defer { host.stop() }
    print("Synthetic demo host on port \(host.port); public demo PSK, local testing only")
    let bytes = SyntheticFrames.bytes(count: 41_666)
    for frame in 0..<(seconds * 60) {
        if let id = state.withLock({ $0.session }) {
            let idr = state.withLock {
                let value = $0.refresh
                $0.refresh = false
                return value
            }
            host.submit(sessionID: id, bytes: bytes, info: SyntheticFrames.info(idr: idr, captureTime: SuspendingClock().now().microseconds))
        }
        if frame % 60 == 0 { print("sent=\(host.stats.path.sent) retransmits=\(host.stats.streams.retransmits) bitrate=\(host.stats.bitrate)") }
        Thread.sleep(forTimeInterval: 1.0 / 60)
    }
}
func runClient(options: Options) throws {
    let port = UInt16(try options.integer("--port", default: 47000, range: 1...65535))
    let seconds = try options.integer("--seconds", default: 60, range: 1...3600)
    let client = try LightrayClient(peer: .init(host: options.value("--host", default: "127.0.0.1"), port: port), pairingID: 1, psk: demoPSK) { _, event in
        switch event {
        case .connected: print("connected")
        case .resumed: print("resumed")
        case .sessionLost: print("session lost")
        case .error(let error): print("error: \(error)")
        default: break
        }
    }
    defer { client.stop() }
    for second in 0..<seconds {
        if options.arguments.contains("--reconnect"), second == seconds / 2 {
            client.park()
            Thread.sleep(forTimeInterval: 0.1)
            client.resume()
        }
        print("frames=\(client.stats.streams.completed) rtt_ms=\(client.stats.path.srtt / 1e6) port=\(client.localPort)")
        Thread.sleep(forTimeInterval: 1)
    }
}
do {
    let options = Options(arguments: Array(CommandLine.arguments.dropFirst()))
    switch options.arguments.first {
    case "benchmark", "loopback": try runLoopback(options: options)
    case "host": try runHost(options: options)
    case "client": try runClient(options: options)
    default: print("Usage: lightray-demo host|client|benchmark [--seconds N] [--port N] [--host IP] [--mbps N] [--reconnect]")
    }
} catch {
    FileHandle.standardError.write(Data("Lightray: \(error)\n".utf8))
    exit(1)
}
