import Testing
@testable import LightrayCore

private final class BridgeLink {
    let key = Bytes(repeating: 7, count: 32)
    let hostAddress = PeerAddress(ip: [127, 0, 0, 1], port: 7373)
    var clientAddress = PeerAddress(ip: [127, 0, 0, 1], port: 50000)
    var now: UInt64 = 10_000_000
    let unix: UInt64 = 1_700_000_000
    let handle: UInt64
    let client: ClientEndpoint
    var received: [DeliveredFrame] = []
    init(wrongKey: Bool = false) {
        handle = bridgeCreate(42, key, 32, Bytes(repeating: 3, count: 32), 32, 20_000_000, 60, 0)
        var config = ClientConfig(pairingID: 42, psk: Bytes(repeating: wrongKey ? 8 : 7, count: 32), host: hostAddress)
        config.videoStreamCount = 1; config.offerFEC = false
        let unix = unix
        client = ClientEndpoint(config: config, unixTime: { unix })
    }
    deinit { _ = bridgeDestroy(handle) }
    func send(_ bytes: Bytes) -> Int32 { bridgeReceive(handle, bytes, Int32(bytes.count), clientAddress.ip, 4, clientAddress.port, now, unix) }
    func pump(_ steps: Int = 10) {
        for _ in 0..<steps {
            now += 250
            client.tick(now: now)
            for packet in client.takeOutboundDatagrams() { #expect(send(packet.bytes) == 0) }
            #expect(bridgeTick(handle, now) == 0)
            var buffer = Bytes(repeating: 0, count: 2048)
            var needed: Int32 = 0
            while bridgePopDatagram(handle, &buffer, 2048, &needed) > 0 {
                #expect(Bytes(buffer[0..<7]) == [4,127,0,0,1,UInt8(clientAddress.port >> 8),UInt8(truncatingIfNeeded: clientAddress.port)])
                client.receive(Bytes(buffer[7..<Int(needed)]), from: hostAddress, now: now)
            }
            while bridgePopEvent(handle, &buffer, 2048, &needed) > 0 {}
            for event in client.takeEvents() {
                if case .frame(_, let frame) = event {
                    received.append(frame)
                    client.decoded(stream: 1, frameID: frame.frameID, isKeyframe: frame.header.frameType == .idr)
                }
            }
        }
    }
    func connect() { client.start(now: now); pump() }
}

@Suite(.serialized) struct HostBridgeTests {
    @Test func handlesAndBounds() {
        #expect(bridgeABIVersion() == 1)
        #expect(bridgeCreate(42, nil, 32, nil, 32, 20_000_000, 60, 0) == 0)
        for _ in 0..<100 {
            let link = BridgeLink()
            #expect(link.handle != 0)
            #expect(bridgeTick(link.handle, UInt64.max) == -1)
            #expect(bridgeTick(link.handle, 100) == 0)
            #expect(bridgeTick(link.handle, 99) == -1)
            #expect(bridgeDestroy(link.handle) == 0)
            #expect(bridgeDestroy(link.handle) == -2)
            #expect(bridgeTick(link.handle, 100) == -2)
        }
    }
    @Test func handshakeAndNonconsumingOutput() {
        let link = BridgeLink(); link.client.start(now: link.now)
        let packet = link.client.takeOutboundDatagrams()[0].bytes
        #expect(link.send(packet) == 0)
        var required: Int32 = 0
        #expect(bridgePopDatagram(link.handle, nil, 0, &required) == -3)
        let size = required
        #expect(size > 7)
        #expect(bridgePopDatagram(link.handle, nil, 0, &required) == -3)
        #expect(required == size)
        var bytes = Bytes(repeating: 0, count: Int(size))
        #expect(bridgePopDatagram(link.handle, &bytes, size, &required) == size)
        link.client.receive(Bytes(bytes[7...]), from: link.hostAddress, now: link.now)
        link.pump()
        #expect(link.client.isConnected)
        #expect(bridgeGeneration(link.handle) == 1)
        var wake: UInt64 = 0
        #expect(bridgeWakeup(link.handle, link.now, &wake) == 0)
        #expect(wake >= link.now)
    }
    @Test func wrongPairingKeyCannotStartSession() {
        let link = BridgeLink(wrongKey: true); link.connect()
        #expect(!link.client.isConnected)
        #expect(bridgeGeneration(link.handle) == 0)
    }
    @Test func mediaAndStaleGeneration() {
        let link = BridgeLink(); link.connect()
        let epoch = bridgeGeneration(link.handle)
        let config: Bytes = [0,0,0,3,64,1,128,0,0,0,3,66,1,128,0,0,0,3,68,1,128]
        let payload: Bytes = [0,0,0,3,38,1,128]
        #expect(bridgeSubmit(link.handle, epoch, 1, payload, 7, config, 21, 1, link.now, link.now) == 0)
        link.pump()
        #expect(link.received.count == 1)
        #expect(Bytes(link.received[0].payload) == payload)
        #expect(link.received[0].header.hostTimings == nil)
        #expect(bridgeSubmit(link.handle, epoch, 2, payload, 7, config, 21, 1, link.now, link.now) == -4)
        #expect(bridgeSubmit(link.handle, epoch, 1, payload, 7, nil, 0, 1, link.now, link.now) == -1)
        #expect(bridgeSubmit(link.handle, epoch, 1, payload, 7, config, 21, 0, link.now, link.now) == -1)
        link.client.start(now: link.now); link.pump()
        #expect(bridgeGeneration(link.handle) == epoch + 1)
        #expect(bridgeSubmit(link.handle, epoch, 1, payload, 7, config, 21, 1, link.now, link.now) == -4)
    }
    @Test func timedSubmissionSurvivesTransportAndRejectsInvalidDurations() {
        let link = BridgeLink(); link.connect()
        let epoch = bridgeGeneration(link.handle)
        let config: Bytes = [0,0,0,3,64,1,128,0,0,0,3,66,1,128,0,0,0,3,68,1,128]
        let payload: Bytes = [0,0,0,3,38,1,128]
        #expect(bridgeSubmitTimed(link.handle, epoch, 1, payload, 7, config, 21, 1, link.now, link.now, 1_000_001, 2, 123) == -1)
        #expect(bridgeSubmitTimed(link.handle, epoch, 1, payload, 7, config, 21, 1, link.now, link.now, 1, 1_000_001, 123) == -1)
        #expect(bridgeSubmitTimed(link.handle, epoch, 1, payload, 7, config, 21, 1, link.now, link.now, 1200, 3400, 123) == 0)
        link.pump()
        #expect(link.received.count == 1)
        #expect(link.received.first?.header.hostTimings == HostFrameTimings(captureMicros: 1200, encodeMicros: 3400, sampleID: 123))
        #expect(bridgeSubmitTimed(link.handle, epoch + 1, 1, payload, 7, config, 21, 1, link.now, link.now, 1, 2, 123) == -4)
    }
    @Test func closePreservesReboundDestination() {
        let link = BridgeLink(); link.connect()
        link.clientAddress.port = 51000
        link.client.session?.connection.queue(.ping(id: 123))
        link.pump()
        #expect(bridgeClose(link.handle, link.now) == 0)
        #expect(bridgeGeneration(link.handle) == 0)
        var bytes = Bytes(repeating: 0, count: 2048); var required: Int32 = 0
        #expect(bridgePopDatagram(link.handle, &bytes, 2048, &required) > 7)
        #expect(bytes[5] == UInt8(51000 >> 8) && bytes[6] == UInt8(truncatingIfNeeded: 51000))
    }
    @Test func pauseInvalidatesQueuedEncoderWork() {
        let link = BridgeLink(); link.connect()
        let old = bridgeGeneration(link.handle)
        link.now += 2_100_000
        #expect(bridgeTick(link.handle, link.now) == 0)
        #expect(bridgeGeneration(link.handle) == old + 1)
        link.client.session?.connection.queue(.ping(id: 321))
        link.pump()
        let payload: Bytes = [0,0,0,3,38,1,128]
        let config: Bytes = [0,0,0,3,64,1,128,0,0,0,3,66,1,128,0,0,0,3,68,1,128]
        #expect(bridgeSubmit(link.handle, old, 1, payload, 7, config, 21, 1, link.now, link.now) == -4)
        #expect(bridgeSubmit(link.handle, old + 1, 1, payload, 7, config, 21, 1, link.now - 100_001, link.now) == -1)
        #expect(bridgeSubmit(link.handle, old + 1, 1, payload, 7, config, 21, 1, link.now, link.now) == 0)
    }
    @Test func undrainedQueuesFailClosed() {
        let link = BridgeLink(); link.client.start(now: link.now)
        let packet = link.client.takeOutboundDatagrams()[0].bytes
        var status: Int32 = 0
        for _ in 0..<300 where status == 0 { status = link.send(packet) }
        #expect(status == -5)
        #expect(bridgeGeneration(link.handle) == 0)
        #expect(bridgeTick(link.handle, link.now) == -5)
        #expect(bridgeDestroy(link.handle) == 0)
    }
    @Test func eventQueryAndInvalidInput() {
        let link = BridgeLink(); link.client.start(now: link.now)
        #expect(link.send(link.client.takeOutboundDatagrams()[0].bytes) == 0)
        var required: Int32 = 0
        #expect(bridgePopEvent(link.handle, nil, 0, &required) == -3)
        #expect(required > 9)
        var bytes = Bytes(repeating: 0, count: 2048)
        #expect(bridgePopEvent(link.handle, &bytes, 2048, &required) > 0)
        #expect(bytes[0] == 1)
        #expect(bridgeReceive(link.handle, nil, 1, [127,0,0,1], 4, 123, link.now, link.unix) == -1)
        #expect(bridgeReceive(link.handle, [0], 1, [127,0,0,1], 3, 123, link.now, link.unix) == -1)
        #expect(bridgeControl(link.handle, 1, [0], 1, link.now) == -1)
    }
}
