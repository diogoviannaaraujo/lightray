import CryptoKit
import LightrayCore
import LightrayCrypto
import LightrayEngine

/// Two `Connection`s wired straight to each other, with no network model and no
/// sockets: the sans-IO core on its own.
///
/// Benchmarks use this to price the protocol per frame, and `protection: .plaintext`
/// separates the protocol's cost from AES-GCM's.
public final class DirectPair {
    public let host: Connection
    public let client: Connection
    public let hostPool = BufferPool()
    public let clientPool = BufferPool()

    private let hostAddress = PeerAddress.synthetic(1, port: 7000)
    private let clientAddress = PeerAddress.synthetic(2, port: 50000)
    private let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 4096, alignment: 64)

    public private(set) var datagramsHostToClient = 0
    public private(set) var datagramsClientToHost = 0
    public private(set) var bytesHostToClient = 0

    public init(config: SessionConfig = SessionConfig(),
                engine: EngineConfig = EngineConfig(),
                capabilities: Capabilities = [.ltr],
                protection mode: PacketProtection.Mode = .aesGCM,
                streams: [StreamDescriptor]? = nil,
                at now: Instant = Instant(nanos: 1_000_000_000)) {
        let table = streams ?? [
            StreamDescriptor(id: 1, kind: .video, direction: .hostToClient, streamClass: .media),
            StreamDescriptor(id: 2, kind: .audio, direction: .hostToClient, streamClass: .realtime),
        ]
        // The handshake is exercised by its own tests; here the two sides are
        // simply given the keys it would have produced.
        let clientToHost = DirectionKeys(SymmetricKey(data: (0..<KeySchedule.outputSize).map { UInt8($0) }))
        let hostToClient = DirectionKeys(SymmetricKey(data: (0..<KeySchedule.outputSize).map { UInt8(0x40 + $0) }))
        host = Connection(role: .host, sessionID: 0x1234_5678,
                          protection: PacketProtection(mode: mode, send: hostToClient, receive: clientToHost),
                          streams: table, config: config, capabilities: capabilities,
                          engine: engine, peer: clientAddress, pool: hostPool, at: now)
        client = Connection(role: .client, sessionID: 0x1234_5678,
                            protection: PacketProtection(mode: mode, send: clientToHost, receive: hostToClient),
                            streams: table, config: config, capabilities: capabilities,
                            engine: engine, peer: hostAddress, pool: clientPool, at: now)
    }

    deinit { buffer.deallocate() }

    /// Moves everything the host has ready to the client. Returns the datagram count.
    @discardableResult
    public func pumpHostToClient(at now: Instant) -> Int {
        var count = 0
        while let outgoing = host.pollTransmit(into: buffer, at: now) {
            let datagram = UnsafeRawBufferPointer(rebasing: buffer[..<outgoing.length])
            client.handle(datagram: datagram, from: hostAddress, at: now)
            count += 1
            bytesHostToClient += outgoing.length
        }
        datagramsHostToClient += count
        return count
    }

    @discardableResult
    public func pumpClientToHost(at now: Instant) -> Int {
        var count = 0
        while let outgoing = client.pollTransmit(into: buffer, at: now) {
            let datagram = UnsafeRawBufferPointer(rebasing: buffer[..<outgoing.length])
            host.handle(datagram: datagram, from: clientAddress, at: now)
            count += 1
        }
        datagramsClientToHost += count
        return count
    }

    /// Submits a frame and carries it all the way to the client, answering the
    /// client's feedback on the way back. Returns the datagrams it took.
    @discardableResult
    public func deliver(_ frame: EncodedFrame, at now: Instant) -> Int {
        host.submit(frame, at: now)
        var total = 0
        // The pacer spreads a frame over its interval, so step through it.
        var at = now
        let step = Interval.milliseconds(1)
        for _ in 0..<64 {
            host.handleTimeout(at: at)
            client.handleTimeout(at: at)
            let sent = pumpHostToClient(at: at)
            total += sent
            pumpClientToHost(at: at)
            if sent == 0 && host.retainedMediaBytes == 0 { break }
            at = at + step
        }
        return total
    }

    /// Drains and drops every event on both sides, so the queues cannot grow
    /// during a long benchmark run.
    public func drainEvents(reportDecoded: Bool = true, at now: Instant = .zero) {
        while let event = client.pollEvent() {
            if case .frameReceived(let frame) = event, reportDecoded {
                client.reportDecoded(stream: frame.stream, frameID: frame.frameID, at: now)
            }
        }
        while host.pollEvent() != nil {}
    }
}
