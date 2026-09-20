import CryptoKit
import Foundation
import LightrayCore
import LightrayCrypto
import LightrayEngine
import LightrayRuntime
import LightrayTestSupport
import Synchronization
import Testing

/// mac -> mac over real UDP on 127.0.0.1: two runtimes, two kqueue threads, two
/// dual-stack sockets. The scenario suite proves the protocol; this proves the
/// Darwin layer under it.
@Suite("Loopback", .serialized)
struct LoopbackTests {

    /// Collects engine events off the loop threads.
    final class Collector: @unchecked Sendable {
        private let state = Mutex<State>(State())
        struct State {
            var clientEvents: [String] = []
            var hostEvents: [String] = []
            var framesDelivered = 0
            var keyframes = 0
            var bytesDelivered = 0
            var frameIDs: [UInt32] = []
            var sessionID: UInt32 = 0
            var parked = 0
            var resumed = 0
            var rebound = 0
            var sessionLost = 0
            var gaps = 0
            /// Streams the host has been asked to refresh, which an app answers
            /// by handing the encoder a forced keyframe.
            var refreshWanted: Set<UInt8> = []
        }

        /// Takes the pending refresh requests, as an app's encoder loop would.
        func takeRefreshRequests() -> Set<UInt8> {
            state.withLock { s in
                let wanted = s.refreshWanted
                s.refreshWanted.removeAll()
                return wanted
            }
        }

        func read<T>(_ body: (State) -> T) -> T { state.withLock { body($0) } }

        func clientEvent(_ event: ConnectionEvent) {
            state.withLock { s in
                switch event {
                case .established(let id, _, _):
                    s.sessionID = id
                    s.clientEvents.append("established")
                case .frameReceived(let frame):
                    s.framesDelivered += 1
                    s.bytesDelivered += frame.payload.count
                    s.frameIDs.append(frame.frameID)
                    if frame.isKeyframe { s.keyframes += 1 }
                case .frameGap: s.gaps += 1
                case .parked: s.parked += 1
                case .resumed: s.resumed += 1
                case .rebound: s.rebound += 1
                case .sessionLost: s.sessionLost += 1
                default: s.clientEvents.append("other")
                }
            }
        }

        func hostEvent(_ event: HostEndpoint.Event) {
            state.withLock { s in
                switch event.event {
                case .parked: s.hostEvents.append("parked")
                case .resumed: s.hostEvents.append("resumed")
                case .rebound: s.hostEvents.append("rebound")
                case .refreshRequired(let stream, _, _):
                    s.hostEvents.append("refreshRequired")
                    s.refreshWanted.insert(stream)
                case .pipelineIdle: s.hostEvents.append("pipelineIdle")
                case .expired: s.hostEvents.append("expired")
                default: break
                }
            }
        }
    }

    static let streams = [
        StreamDescriptor(id: 1, kind: .video, direction: .hostToClient, streamClass: .media),
        StreamDescriptor(id: 2, kind: .audio, direction: .hostToClient, streamClass: .realtime),
        StreamDescriptor(id: 3, kind: .input, direction: .clientToHost, streamClass: .reliable),
    ]

    /// Real time, so tests wait on a condition rather than a fixed sleep.
    static func waitUntil(_ timeout: TimeInterval = 5, _ condition: @Sendable () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(2_000)
        }
        return condition()
    }

    struct Pair {
        var host: LightrayHost
        var client: LightrayClient
        var collector: Collector
    }

    static func makePair(config: SessionConfig = {
        var c = SessionConfig()
        c.bitrate = 8_000_000
        return c
    }(), engine: EngineConfig = EngineConfig()) throws -> Pair {
        let psk = SymmetricKey(data: [UInt8](repeating: 0x5A, count: 32))
        let collector = Collector()
        let host = try LightrayHost(psk: psk, streams: streams, config: config, engine: engine,
                                    onEvent: { [collector] in collector.hostEvent($0) })
        let client = try LightrayClient(psk: psk, pairingID: 0xBEEF, streams: streams,
                                        config: config, engine: engine,
                                        onEvent: { [collector] in collector.clientEvent($0) })
        host.start()
        client.start()
        return Pair(host: host, client: client, collector: collector)
    }

    @Test func handshakeOverRealUDP() throws {
        let pair = try Self.makePair()
        defer { pair.client.stop(); pair.host.stop() }
        #expect(pair.host.localPort != 0, "the host bound a port")
        pair.client.connect(host: "127.0.0.1", port: pair.host.localPort)

        let connected = Self.waitUntil { pair.client.phase == .connected }
        #expect(connected, "handshake completed over loopback")
        #expect(pair.collector.read { $0.sessionID } != 0)
        #expect(pair.host.snapshots().count <= 1)
    }

    @Test func framesFlowOverRealUDP() throws {
        let pair = try Self.makePair()
        defer { pair.client.stop(); pair.host.stop() }
        pair.client.connect(host: "127.0.0.1", port: pair.host.localPort)
        #expect(Self.waitUntil { pair.client.phase == .connected })

        var source = SyntheticFrameSource(stream: 1, bitrate: 8_000_000, framerate: 60)
        for _ in 0..<60 {
            pair.host.submit(source.next(at: SystemClock.shared.now(), forceIDR: false))
            usleep(16_666)
        }

        let got = Self.waitUntil { pair.collector.read { $0.framesDelivered } >= 50 }
        let state = pair.collector.read { $0 }
        #expect(got, "delivered \(state.framesDelivered) of 60 frames over loopback")
        #expect(state.keyframes >= 1, "the first frame was an IDR")
        #expect(state.bytesDelivered > 0)
        #expect(state.frameIDs == Array(state.frameIDs.min()!...state.frameIDs.max()!),
                "frame ids arrived contiguous and in order")
        let sent = pair.host.loopStats
        #expect(sent.sent > 0 && sent.sendErrors == 0, "\(sent.sent) datagrams, \(sent.sendErrors) errors")
    }

    /// The manual check from the plan, automated: force a new client port
    /// mid-stream and watch park -> resume -> IDR.
    @Test func newClientPortMidStreamResumesWithAnIDR() throws {
        var engine = EngineConfig()
        engine.parkAfterSilence = .milliseconds(300)
        engine.keepaliveInterval = .milliseconds(100)
        let pair = try Self.makePair(engine: engine)
        defer { pair.client.stop(); pair.host.stop() }
        pair.client.connect(host: "127.0.0.1", port: pair.host.localPort)
        #expect(Self.waitUntil { pair.client.phase == .connected })

        var source = SyntheticFrameSource(stream: 1, bitrate: 8_000_000, framerate: 60)
        /// What an app's encoder loop does: emit a frame each interval, forcing a
        /// keyframe whenever the protocol has asked for one.
        func pump(frames: Int) {
            for _ in 0..<frames {
                let forced = !pair.collector.takeRefreshRequests().isEmpty
                pair.host.submit(source.next(at: SystemClock.shared.now(), forceIDR: forced))
                usleep(16_666)
            }
        }
        pump(frames: 30)
        #expect(Self.waitUntil { pair.collector.read { $0.framesDelivered } >= 10 })
        let portBefore = pair.client.localPort
        let keyframesBefore = pair.collector.read { $0.keyframes }

        // Park, then come back on a fresh socket.
        pair.client.park()
        #expect(Self.waitUntil { pair.collector.read { $0.parked } >= 1 }, "the client parked")
        usleep(200_000)
        pair.client.resume(decoderLost: false)
        #expect(Self.waitUntil { pair.client.localPort != portBefore },
                "the resume replaced the socket: \(portBefore) -> \(pair.client.localPort)")

        // A resume is always an IDR: the engine asks, and the app's encoder loop
        // answers with a forced keyframe.
        pump(frames: 40)
        let recovered = Self.waitUntil(3) { pair.collector.read { $0.keyframes } > keyframesBefore }
        let state = pair.collector.read { $0 }
        #expect(recovered, "a new IDR arrived after the resume (keyframes \(state.keyframes))")
        #expect(state.resumed >= 1)
        #expect(state.hostEvents.contains("resumed") || state.hostEvents.contains("rebound"))
    }

    /// Reliable input in the client-to-host direction, over the real socket.
    @Test func reliableInputOverRealUDP() throws {
        let psk = SymmetricKey(data: [UInt8](repeating: 0x5A, count: 32))
        let received = Mutex<[UInt8]>([])
        let host = try LightrayHost(psk: psk, streams: Self.streams, config: SessionConfig(),
                                    onEvent: { event in
            if case .reliableMessage(let stream, let bytes) = event.event, stream == 3, let first = bytes.first {
                received.withLock { $0.append(first) }
            }
        })
        let client = try LightrayClient(psk: psk, pairingID: 0xBEEF, streams: Self.streams,
                                        config: SessionConfig())
        host.start(); client.start()
        defer { client.stop(); host.stop() }
        client.connect(host: "127.0.0.1", port: host.localPort)
        #expect(Self.waitUntil { client.phase == .connected })

        for i in 0..<30 { client.sendReliable([UInt8(i)], stream: 3) }
        let all = Self.waitUntil { received.withLock { $0.count } == 30 }
        let order = received.withLock { $0 }
        #expect(all, "received \(order.count) of 30 input messages")
        #expect(order == Array(0..<30).map(UInt8.init), "and in order")
    }

    /// The socket options the plan depends on, checked against the real kernel.
    @Test func socketOptionsBehaveAsMeasured() throws {
        let socket = try UDPSocket(port: 0)
        #expect(socket.localPort != 0)

        // SO_RCVBUF is silently capped at kern.ipc.maxsockbuf (8 MB), so asking
        // for more is pointless: read back what we actually got.
        var value: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        _ = getsockopt(socket.fd, SOL_SOCKET, SO_RCVBUF, &value, &length)
        #expect(value >= 1 << 20, "receive buffer is \(value) bytes")
        #expect(value <= UDPSocket.maxSocketBuffer, "and capped at the kernel limit")

        // A fresh socket gets a different ephemeral port, which is what makes a
        // resume visible to the host as a rebind.
        let second = try UDPSocket(port: 0)
        #expect(second.localPort != socket.localPort)

        // Loopback round trip through the dual-stack socket.
        let payload: [UInt8] = [1, 2, 3, 4]
        let sent = payload.withUnsafeBytes { raw in
            socket.send(raw, to: UDPSocket.loopback(port: second.localPort))
        }
        #expect(sent == 4)
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 64, alignment: 16)
        defer { buffer.deallocate() }
        var got: (length: Int, from: PeerAddress)?
        let deadline = Date().addingTimeInterval(1)
        while got == nil, Date() < deadline {
            got = second.receive(into: buffer)
            if got == nil { usleep(1_000) }
        }
        #expect(got?.length == 4, "the datagram arrived on 127.0.0.1")
    }
}
