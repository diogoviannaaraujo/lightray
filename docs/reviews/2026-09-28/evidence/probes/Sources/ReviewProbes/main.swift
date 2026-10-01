import LightrayCore

// These probes record the reviewed behavior, not acceptance criteria for a future fix.
// All cryptographic inputs are synthetic fixtures; no stored pairing is read.
let originalAddress = PeerAddress(ip: [192, 0, 2, 1], port: 7373)
let clientAddress = PeerAddress(ip: [192, 0, 2, 2], port: 50000)
let testKey = Bytes(repeating: 7, count: 32)

func connect() -> (ClientEndpoint, HostEndpoint) {
    let client = ClientEndpoint(config: ClientConfig(pairingID: 42, psk: testKey, host: originalAddress), unixTime: { 1_700_000_000 })
    let host = HostEndpoint(config: HostConfig(), hostSecret: Bytes(repeating: 3, count: 32), psk: { $0 == 42 ? testKey : nil })
    client.start(now: 1_000_000)
    for datagram in client.takeOutbox() { host.receive(datagram, from: clientAddress, now: 1_001_000, unixTime: 1_700_000_000) }
    for (datagram, _) in host.takeOutbox() { client.receive(datagram, from: originalAddress, now: 1_002_000) }
    precondition(client.isConnected)
    return (client, host)
}

func malformedParity() -> MediaFragment {
    let fragment = MediaFragment(stream: 1, flags: MediaFragment.Flag.parity, frameID: 1, index: 0, count: 1, stride: 64, fec: .init(maxBlockLength: 1, parityPerBlock: 1, lastLength: 65), payload: Bytes(repeating: 0, count: 64)[...])
    guard case .mediaFragment(let parsed)? = Chunk.parse(Chunk.mediaFragment(fragment).encoded).chunks.first else { preconditionFailure("Malformed parity was rejected: update the finding") }
    return parsed
}

if CommandLine.arguments.contains("--crash-parity") {
    // Deliberately exercise the trap in a separate disposable process.
    VideoReceiver(stream: 1).receive(malformedParity(), now: 1_000, budget: 50_000)
    preconditionFailure("Expected parity trap no longer reproduced")
}

let parity = malformedParity()
print("R01: parser accepts parity lastLength=\(parity.fec!.lastLength), stride=\(parity.stride)")

let emptyConfig = CodecConfig(vps: [], sps: [], pps: [])
let invalidIDR = FrameHeader(frameType: .idr, refKind: .none, captureTimeMicros: 0, codecConfig: emptyConfig).encoded
precondition(FrameHeader.parse(invalidIDR) != nil)
print("R02: frame parser accepts empty VPS/SPS/PPS (decoder crash not exercised)")

let receiver = VideoReceiver(stream: 1)
for index in stride(from: 0, through: 62, by: 2) {
    let fragment = MediaFragment(stream: 1, flags: 0, frameID: 1, index: UInt16(index), count: 64, stride: 200, payload: Bytes(repeating: 0, count: 200)[...])
    receiver.receive(fragment, now: 1_000, budget: 50_000)
}
let connection = Connection(role: .client, sessionID: 1, sendKey: testKey, receiveKey: testKey, streams: StreamTable([]), maxDatagramSize: 256, peer: originalAddress, now: 1_000)
for chunk in receiver.poll(now: 10_000, srtt: 2_000, budget: 50_000) { connection.queue(chunk) }
let largest = connection.flush(now: 10_000).map(\.count).max() ?? 0
precondition(largest > 256)
print("R03: generated NACK datagram=\(largest) bytes, negotiated maximum=256")

let (client, host) = connect()
for _ in 0..<1024 { client.send(.key(usage: 4, down: true, isRepeat: true), now: 1_003_000) }
client.send(.key(usage: 4, down: false, isRepeat: false), now: 1_003_000)
client.tick(now: 1_004_000)
for datagram in client.takeOutbox() { host.receive(datagram, from: clientAddress, now: 1_005_000, unixTime: 1_700_000_000) }
var presses = 0
var releases = 0
for event in host.takeEvents() {
    if case .input(.key(_, let down, _)) = event { if down { presses += 1 } else { releases += 1 } }
}
precondition(presses == 1024 && releases == 0)
print("R04: full reliable queue delivers \(presses) presses and \(releases) releases")

let changedAddress = PeerAddress(ip: originalAddress.ip, port: 7374)
host.session!.connection.queue(.ping(id: 99))
for datagram in host.session!.connection.flush(now: 1_006_000) { client.receive(datagram, from: changedAddress, now: 1_007_000) }
precondition(client.session!.connection.peer == changedAddress && client.config.host != changedAddress)
print("R05: authenticated host rebind updates peer port to 7374; application send target remains config.host port 7373")
