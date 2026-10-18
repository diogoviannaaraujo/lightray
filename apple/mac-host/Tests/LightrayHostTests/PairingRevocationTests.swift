import Foundation
import Testing
import LightrayCore
@testable import LightrayHostRuntime

/// Pairings a test changes by hand, as a revocation in the store would.
private final class TestPairings: HostPairings, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [UInt64: Bytes]
    private var changed = false
    private var connections: [UInt64] = []
    init(_ pairing: Pairing) { keys = [pairing.id: pairing.psk] }
    func key(for id: UInt64) -> Bytes? { lock.withLock { keys[id] } }
    func refresh() -> Bool { lock.withLock { defer { changed = false }; return changed } }
    func connected(_ id: UInt64) { lock.withLock { connections.append(id) } }
    func revoke(_ id: UInt64) { lock.withLock { keys[id] = nil; changed = true } }
    var connected: [UInt64] { lock.withLock { connections } }
}

/// A client endpoint driven over a real socket, on a queue of its own.
private final class LoopbackClient: @unchecked Sendable {
    let queue = DispatchQueue(label: "revocation.client")
    let socket: UDPSocket
    let endpoint: ClientEndpoint
    private var timer: DispatchSourceTimer?
    private(set) var events: [ClientEvent] = []

    init(pairing: Pairing, port: UInt16) throws {
        socket = try UDPSocket(queue: queue)
        var config = ClientConfig(pairingID: pairing.id, psk: pairing.psk,
                                  host: PeerAddress(ip: Bytes(repeating: 0, count: 15) + [1], port: port))
        config.videoStreamCount = 1
        endpoint = ClientEndpoint(config: config, unixTime: unixSeconds)
    }

    func start() {
        queue.sync {
            socket.start { [unowned self] datagram, from in
                endpoint.receive(datagram, from: from, now: monotonicMicros())
                pump()
            }
            endpoint.start(now: monotonicMicros())
            pump()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(10))
            timer.setEventHandler { [unowned self] in endpoint.tick(now: monotonicMicros()); pump() }
            timer.resume()
            self.timer = timer
        }
    }

    private func pump() {
        for datagram in endpoint.takeOutboundDatagrams() { _ = socket.send(datagram.bytes, to: datagram.destination) }
        events += endpoint.takeEvents()
    }

    var connections: Int { queue.sync { events.filter { if case .connected = $0 { true } else { false } }.count } }
    var disconnections: [String] {
        queue.sync { events.compactMap { if case .disconnected(let reason) = $0 { reason } else { nil } } }
    }

    func stop() {
        queue.sync { timer?.cancel(); timer = nil; socket.close() }
    }
}

private func waitUntil(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
    let deadline = Date() + seconds
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

@Test func revokedDeviceIsDisconnectedAndCannotReconnect() async throws {
    let probe = try UDPSocket(port: 0, queue: DispatchQueue(label: "revocation.probe"))
    let port = probe.localPort
    probe.close()
    var options = HostOptions()
    options.port = port; options.testPattern = (320, 240); options.inputMode = .off; options.warmSeconds = 0
    let pairing = Pairing.generate()
    let pairings = TestPairings(pairing)
    let host = HostApp(options: options, pairings: pairings)
    try await host.run()
    let client = try LoopbackClient(pairing: pairing, port: port)
    defer { client.stop() }
    client.start()

    #expect(await waitUntil(5) { client.connections == 1 && host.connectedPairing == pairing.id })
    #expect(pairings.connected == [pairing.id])

    pairings.revoke(pairing.id)
    #expect(await waitUntil(3) { client.disconnections.contains { $0.contains("closed") } })
    #expect(host.connectedPairing == nil)
    // The client starts a new handshake a second later; the host leaves it unanswered.
    try await Task.sleep(for: .seconds(2.5))
    #expect(client.connections == 1)
    await host.stop()
}
