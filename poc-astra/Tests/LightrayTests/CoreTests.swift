import Foundation
import LightrayCrypto
import LightrayPrimitives
import LightrayStats
import LightrayStreams
import LightrayTestSupport
import LightrayWire
import Testing

func encodedFragment(bytes: [UInt8], index: Int, frameID: UInt32 = 7, mtu: Int = 1200) throws -> [UInt8] {
    let fragmenter = try Fragmenter(maxDatagramSize: mtu)
    return try [UInt8](unsafeUninitializedCapacity: mtu) { buffer, count in
        let raw = UnsafeMutableRawBufferPointer(buffer)
        var writer = OutputRawSpan(buffer: raw, initializedCount: 0)
        try bytes.withUnsafeBytes { try fragmenter.encode(frame: $0, stream: 1, frameID: frameID, index: index, into: &writer) }
        count = writer.finalize(for: raw)
    }
}
@Test func serialNumbersAndSaturatingTime() {
    do {
        let actual = (SerialNumber.isNewer(0, than: .max))
        #expect(actual)
    }
    do {
        let actual = (!SerialNumber.isNewer(.max, than: 0))
        #expect(actual)
    }
    do {
        let actual = (!SerialNumber.isNewer(7, than: 7))
        #expect(actual)
    }
    do {
        let actual = (Instant(.max - 2).advanced(by: 10).nanoseconds == .max)
        #expect(actual)
    }
    do {
        let actual = (Instant(1).elapsed(since: Instant(2)) == 0)
        #expect(actual)
    }
}
@Test func poolLeasesAndBoundedRing() {
    let pool = BufferPool(bufferSize: 1200, capacity: 1)
    var lease = pool.acquire()
    do {
        let actual = (pool.available == 0)
        #expect(actual)
    }
    do {
        let actual = (pool.acquire() == nil)
        #expect(actual)
    }
    do {
        let actual = (lease?.capacity == 1200)
        #expect(actual)
    }
    lease = nil
    do {
        let actual = (pool.available == 1)
        #expect(actual)
    }
    var ring = RingBuffer<Int>(capacity: 2)
    do {
        let actual = (ring.append(1))
        #expect(actual)
    }
    do {
        let actual = (ring.append(2))
        #expect(actual)
    }
    do {
        let actual = (!ring.append(3))
        #expect(actual)
    }
    do {
        let actual = (ring.popFirst() == 1)
        #expect(actual)
    }
    do {
        let actual = (ring.append(3))
        #expect(actual)
    }
    do {
        let actual = (ring.popFirst() == 2)
        #expect(actual)
    }
    do {
        let actual = (ring.popFirst() == 3)
        #expect(actual)
    }
}
@Test func wireGoldenHeaderAndFragment() throws {
    let vector: [UInt8] = [0, 0, 0, 0, 1, 2, 3, 4, 0xff, 0xff, 0xff, 0xff, 0x11, 0x22, 0x33, 0x44]
    var reader = ByteReader(vector.span.bytes)
    let header = try PacketHeader.decode(&reader)
    do {
        let actual = (header.sessionID == 0x0102_0304)
        #expect(actual)
    }
    do {
        let actual = (header.transportSeq == .max)
        #expect(actual)
    }
    do {
        let actual = (header.sendTimeUs == 0x1122_3344)
        #expect(actual)
    }
    let bytes = try encodedFragment(bytes: [0xaa, 0xbb], index: 0)
    do {
        let actual = (bytes == [1, 0, 18, 1, 0, 0, 0, 0, 7, 0, 0, 0, 1, 4, 0x7d, 3, 1, 1, 0, 0xaa, 0xbb])
        #expect(actual)
    }
    var chunks = ByteReader(bytes.span.bytes)
    let chunk = try chunks.nextChunk()!
    var body = ByteReader(chunk.body)
    let fragment = try body.fragment()
    do {
        let actual = (fragment.header.stride == 1149)
        #expect(actual)
    }
    do {
        let actual = (fragment.payload.byteCount == 2)
        #expect(actual)
    }
}
@Test func frameAndConfigurationRoundTripUnknownTLVs() throws {
    let original = FrameInfo(type: .idr, reference: .ltr, referenceID: 99, ltrMark: true, generation: 4, captureTime: .max, codecConfig: [1, 2, 3])
    let bytes = try original.encode()
    var reader = ByteReader(bytes.span.bytes)
    do {
        let actual = (try FrameInfo.decode(&reader) == original)
        #expect(actual)
    }
    var config = Configuration()
    config.maxDatagramSize = 1400
    let encoded = config.encode() + [0xff, 0, 3, 1, 2, 3]
    do {
        let actual = (try Configuration.decode(encoded.span.bytes) == config)
        #expect(actual)
    }
    #expect(throws: WireError.self) { try FrameInfo(type: .idr).encode() }
}
@Test func reassemblyLastFragmentFirstAndDuplicates() throws {
    let bytes = SyntheticFrames.bytes(count: 500_000)
    let reassembler = Reassembler()
    let count = try Fragmenter(maxDatagramSize: 1200).fragmentCount(byteCount: bytes.count)
    var result: ReassembledFrame?
    for index in (0..<count).reversed() {
        let packet = try encodedFragment(bytes: bytes, index: index)
        var r = ByteReader(packet.span.bytes)
        let chunk = try r.nextChunk()!
        var b = ByteReader(chunk.body)
        let fragment = try b.fragment()
        result = try reassembler.receive(fragment, at: .init(42))
        if index > 0 {
            do {
                let actual = (try reassembler.receive(fragment, at: .init(43)) == nil)
                #expect(actual)
            }
        }
    }
    let frame = try #require(result)
    do {
        let actual = (frame.withUnsafeBytes { Array($0) } == bytes)
        #expect(actual)
    }
    do {
        let actual = (reassembler.allocatedBytes == 0)
        #expect(actual)
    }
}
@Test func reassemblyRejectsInconsistentMetadataAndBudget() throws {
    let reassembler = Reassembler(maxBytes: 2000)
    let bytes = try encodedFragment(bytes: [UInt8](repeating: 1, count: 3000), index: 0)
    var r = ByteReader(bytes.span.bytes)
    let chunk = try r.nextChunk()!
    var b = ByteReader(chunk.body)
    let fragment = try b.fragment()
    #expect(throws: WireError.self) { try reassembler.receive(fragment, at: .init()) }
}
@Test func fuzzWireTruncationAndMutations() throws {
    let seed = try encodedFragment(bytes: SyntheticFrames.bytes(count: 1149), index: 0)
    var random = SeededRandom(seed: 42)
    var rejected = 0
    for _ in 0..<20_000 {
        var bytes = Array(seed.prefix(Int(random.next() % UInt64(seed.count + 1))))
        if !bytes.isEmpty { bytes[Int(random.next() % UInt64(bytes.count))] = UInt8(truncatingIfNeeded: random.next()) }
        do {
            var r = ByteReader(bytes.span.bytes)
            while let chunk = try r.nextChunk() {
                if chunk.type == 1 {
                    var body = ByteReader(chunk.body)
                    _ = try body.fragment()
                }
            }
        } catch { rejected += 1 }
    }
    #expect(rejected > 0)
}
@Test func cryptoRejectsTamperingReplayAndWrongKey() throws {
    let protection = try AESGCMProtection(key: .init(repeating: 7, count: 16), iv: .init(repeating: 9, count: 12))
    let header = [UInt8](repeating: 0, count: 16)
    let plaintext: [UInt8] = [1, 2, 3]
    let sealed = try protection.seal(plaintext, header: header, packetNumber: 42)
    do {
        let actual = (try protection.open(sealed, header: header, packetNumber: 42) == plaintext)
        #expect(actual)
    }
    var tampered = sealed
    tampered[0] ^= 1
    #expect(throws: (any Error).self) { try protection.open(tampered, header: header, packetNumber: 42) }
    #expect(throws: (any Error).self) { try protection.open(sealed, header: header, packetNumber: 43) }
    var aad = header
    aad[5] ^= 1
    #expect(throws: (any Error).self) { try protection.open(sealed, header: aad, packetNumber: 42) }
    do {
        let actual = (protection.nonce(packetNumber: 0) != protection.nonce(packetNumber: 1 << 32))
        #expect(actual)
    }
    var replay = ReplayWindow()
    do {
        let actual = (replay.commit(0xffff_ffff))
        #expect(actual)
    }
    do {
        let actual = (replay.reconstruct(0) == 0x1_0000_0000)
        #expect(actual)
    }
    do {
        let actual = (replay.commit(0x1_0000_0000))
        #expect(actual)
    }
    do {
        let actual = (!replay.commit(0xffff_ffff))
        #expect(actual)
    }
    do {
        let actual = (replay.commit(0x1_0000_0000 + 2048))
        #expect(actual)
    }
    do {
        let actual = (!replay.accepts(0x1_0000_0000))
        #expect(actual)
    }
}
@Test func handshakeRoundTripRetransmissionAndReplayGuard() throws {
    let psk = [UInt8](repeating: 3, count: 32)
    let initiator = try HandshakeInitiator(pairingID: 42, psk: psk)
    let responder = try HandshakeResponder(secret: .init(repeating: 5, count: 32))
    let initial = try initiator.start(configuration: .init(), timestamp: 100)
    do {
        let actual = (initial.count == 1200)
        #expect(actual)
    }
    let response = try responder.accept(initial, psk: psk, sessionID: 8, timestamp: 100)
    let client = try initiator.finish(response.packet)
    let host = try #require(response.result)
    do {
        let actual = (client.sessionID == 8)
        #expect(actual)
    }
    do {
        let actual = (client.configuration == host.configuration)
        #expect(actual)
    }
    let payload: [UInt8] = [1, 2, 3]
    let encrypted = try client.keys.clientToHost.seal(payload, header: [], packetNumber: 1)
    do {
        let actual = (try host.keys.clientToHost.open(encrypted, header: [], packetNumber: 1) == payload)
        #expect(actual)
    }
    do {
        let actual = (try responder.accept(initial, psk: psk, sessionID: 9, timestamp: 100).result == nil)
        #expect(actual)
    }
    #expect(throws: (any Error).self) { try responder.accept(initial, psk: .init(repeating: 4, count: 32), sessionID: 9, timestamp: 100) }
    #expect(throws: (any Error).self) { try responder.accept(initial, psk: psk, sessionID: 9, timestamp: 131) }
    var mismatch = initial
    mismatch[1] = 1
    #expect(throws: (any Error).self) { try responder.accept(mismatch, psk: psk, sessionID: 9, timestamp: 100) }
}
@Test func reliableReorderDuplicatesAndRetransmission() throws {
    let sender = ReliableChannel()
    let receiver = ReliableChannel()
    _ = try sender.send([1, 2, 3, 4, 5], maxPayload: 2, at: .init())
    _ = try sender.send([6, 7], maxPayload: 2, at: .init())
    let segments = sender.poll(at: .init(), rto: 10_000_000)
    do {
        let actual = (try receiver.receive(segments.last!).messages.isEmpty)
        #expect(actual)
    }
    var delivered: [[UInt8]] = []
    for segment in segments.dropLast().reversed() {
        let result = try receiver.receive(segment)
        delivered += result.messages
        for ack in result.acknowledged { sender.acknowledge(ack) }
    }
    do {
        let actual = (delivered == [[1, 2, 3, 4, 5], [6, 7]])
        #expect(actual)
    }
    do {
        let actual = (sender.pendingCount == 0)
        #expect(actual)
    }
    do {
        let actual = (try receiver.receive(segments[0]).acknowledged == [0])
        #expect(actual)
    }
}
@Test func pacingBackstopAndLTRGating() throws {
    let pacer = Pacer(maxBurstBytes: 1200)
    try pacer.enqueue([UInt8](repeating: 0, count: 1168), priority: .video, at: .init())
    try pacer.enqueue([1], priority: .control, at: .init())
    do {
        let actual = (pacer.poll(at: .init()) == [1])
        #expect(actual)
    }
    do {
        let actual = (pacer.poll(at: .init()) == nil)
        #expect(actual)
    }
    do {
        let actual = (pacer.poll(at: .init(1_000_000))?.count == 1168)
        #expect(actual)
    }
    var controller = BitrateController()
    for _ in 0..<3 {
        do {
            let actual = (!controller.recordWindow(received: 80, lost: 20))
            #expect(actual)
        }
    }
    do {
        let actual = (controller.recordWindow(received: 80, lost: 20))
        #expect(actual)
    }
    do {
        let actual = (controller.target == controller.floor)
        #expect(actual)
    }
    controller.setTarget(30_000_000)
    do {
        let actual = (!controller.backstop)
        #expect(actual)
    }
    var tracker = DecodabilityTracker()
    do {
        let actual = (tracker.accept(id: 0, info: SyntheticFrames.info(idr: true)))
        #expect(actual)
    }
    tracker.decodedLTR(0)
    do {
        let actual = (!tracker.accept(id: 2, info: SyntheticFrames.info(idr: false)))
        #expect(actual)
    }
    do {
        let actual = (tracker.accept(id: 3, info: .init(reference: .ltrAny)))
        #expect(actual)
    }
    tracker.reset()
    do {
        let actual = (!tracker.accept(id: 4, info: .init(reference: .ltrAny)))
        #expect(actual)
    }
}
@Test func normativeJSONVectorsAndNISTAESGCM() throws {
    let url = try #require(Bundle.module.url(forResource: "protocol-v0", withExtension: "json", subdirectory: "Vectors"))
    let vectors = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
    func hex(_ text: String) -> [UInt8] {
        precondition(text.count % 2 == 0)
        return stride(from: 0, to: text.count, by: 2).map { offset in
            let start = text.index(text.startIndex, offsetBy: offset)
            let end = text.index(start, offsetBy: 2)
            return UInt8(text[start..<end], radix: 16)!
        }
    }
    for vector in vectors {
        let name = try #require(vector["name"] as? String)
        if name == "aes128_gcm_nist" {
            let protection = try AESGCMProtection(key: hex(vector["key_hex"] as! String), iv: hex(vector["iv_hex"] as! String))
            let sealed = try protection.seal(hex(vector["plaintext_hex"] as! String), header: [], packetNumber: 0)
            #expect(sealed == hex(vector["sealed_hex"] as! String))
        } else {
            let bytes = hex(vector["hex"] as! String)
            var reader = ByteReader(bytes.span.bytes)
            if name == "protected_header" {
                let header = try PacketHeader.decode(&reader)
                #expect(header.sessionID == 0x0102_0304)
            } else {
                let chunk = try reader.nextChunk()!
                #expect(reader.remaining == 0)
                #expect(chunk.body.byteCount == bytes.count - 3)
            }
        }
    }
}
@Test func feedbackRoundTripWithReliableAcknowledgments() throws {
    let cases: [[Int16?]] = [[0, nil, -12, 100], []]
    for arrivals in cases {
        let original = Feedback(base: .max - 2, baseArrival: .max, arrivals: arrivals, reliableAcknowledgments: [.init(stream: 5, sequence: 42)])
        let bytes = try original.encode()
        var reader = ByteReader(bytes.span.bytes)
        let decoded = try Feedback.decode(&reader)
        #expect(decoded.base == original.base)
        #expect(decoded.arrivals == original.arrivals)
        #expect(decoded.reliableAcknowledgments == original.reliableAcknowledgments)
    }
}
