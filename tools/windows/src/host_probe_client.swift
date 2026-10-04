// Test-only peer for the MSVC ABI harness. Fixed public fixture key; never ship in a product.
private final class ProbeClient {
    let endpoint: ClientEndpoint
    var packets: [Bytes] = []
    var frames: [Bytes] = []
    init(now: UInt64) {
        var config = ClientConfig(pairingID: 42, psk: Bytes(repeating: 7, count: 32), host: PeerAddress(ip: [127,0,0,1], port: 7373))
        config.videoStreamCount = 1; config.offerFEC = false
        endpoint = ClientEndpoint(config: config, unixTime: { 1_700_000_000 })
        endpoint.start(now: now)
    }
    func collect() -> Int32 {
        packets += endpoint.takeOutboundDatagrams().map(\.bytes)
        for event in endpoint.takeEvents() {
            if case .frame(let stream, let frame) = event {
                frames.append(Bytes(frame.payload))
                endpoint.decoded(stream: stream, frameID: frame.frameID, isKeyframe: frame.header.frameType == .idr)
            }
        }
        return packets.count <= 256 && frames.count <= 4 ? 0 : -5
    }
}
// This test peer is used on one harness thread. Production synchronization is in host_bridge.swift.
nonisolated(unsafe) private var probeClient: ProbeClient?
@_cdecl("lr_probe_client_start")
public func probeClientStart(_ now: UInt64) -> Int32 {
    guard now < 1_000_000_000 else { return -1 }
    probeClient = ProbeClient(now: now)
    return probeClient!.collect()
}
@_cdecl("lr_probe_client_step")
public func probeClientStep(_ bytes: UnsafePointer<UInt8>?, _ count: Int32, _ now: UInt64) -> Int32 {
    guard let client = probeClient, count >= 0, count <= 1200, now < 1_000_000_000 else { return -1 }
    if count > 0 {
        guard let bytes else { return -1 }
        client.endpoint.receive(Bytes(UnsafeBufferPointer(start: bytes, count: Int(count))), from: PeerAddress(ip: [127,0,0,1], port: 7373), now: now)
    }
    client.endpoint.tick(now: now)
    return client.collect()
}
@_cdecl("lr_probe_client_pop")
public func probeClientPop(_ frame: Int32, _ output: UnsafeMutablePointer<UInt8>?, _ capacity: Int32) -> Int32 {
    guard let client = probeClient, let output, capacity >= 0 else { return -1 }
    guard let bytes = frame == 0 ? client.packets.first : client.frames.first else { return 0 }
    guard capacity >= bytes.count else { return -3 }
    for (index, byte) in bytes.enumerated() { output[index] = byte }
    if frame == 0 { client.packets.removeFirst() } else { client.frames.removeFirst() }
    return Int32(bytes.count)
}
@_cdecl("lr_probe_client_stop")
public func probeClientStop() { probeClient = nil }
