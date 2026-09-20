import Benchmark
import Lightray
import LightrayCrypto
import LightrayTestSupport

enum AllocationFailure: Error { case observed(Int) }
let benchmarks: @Sendable () -> Void = {
    let datagram: [UInt8] = {
        var bytes = [UInt8](repeating: 0x5a, count: 1200)
        bytes.withUnsafeMutableBytes { raw in
            var writer = OutputRawSpan(buffer: raw, initializedCount: 0)
            try! PacketHeader(flags: 0, sessionID: 1, transportSeq: 1, sendTimeUs: 0).encode(into: &writer)
            try! writer.put(UInt8(1))
            try! writer.put(UInt16(1165))
            try! FragmentHeader(stream: 1, flags: 0, frameID: 1, index: 0, count: 2).encode(into: &writer)
            _ = writer.finalize(for: raw)
        }
        return bytes
    }()
    Benchmark("Wire header and fragment decode", configuration: .init(metrics: [.wallClock, .instructions], scalingFactor: .kilo)) { benchmark in
        benchmark.startMeasurement()
        for _ in benchmark.scaledIterations {
            var reader = ByteReader(datagram.span.bytes)
            let header = try PacketHeader.decode(&reader)
            var chunks = ByteReader(try reader.take(reader.remaining - 16))
            while let chunk = try chunks.nextChunk() {
                var fragment = ByteReader(chunk.body)
                Benchmark.blackHole(try fragment.fragment().header.frameID &+ header.transportSeq)
            }
        }
    }
    Benchmark("Receive parse place stats steady state", configuration: .init(metrics: [.wallClock], scalingFactor: .kilo)) { benchmark in
        let receiver = Reassembler(maxBytes: 128 * 1024 * 1024)
        var stats = PathStats()
        var packet = datagram
        packet[27] = 0xff
        packet[28] = 0xff
        do {
            var initial = ByteReader(packet.span.bytes)
            _ = try PacketHeader.decode(&initial)
            var chunks = ByteReader(try initial.take(initial.remaining - 16))
            let chunk = try chunks.nextChunk()!
            var body = ByteReader(chunk.body)
            _ = try receiver.receive(body.fragment(), at: .init())
        }
        benchmark.startMeasurement()
        for index in benchmark.scaledIterations {
            packet[25] = UInt8(truncatingIfNeeded: (index + 1) >> 8)
            packet[26] = UInt8(truncatingIfNeeded: index + 1)
            var reader = ByteReader(packet.span.bytes)
            let header = try PacketHeader.decode(&reader)
            var chunks = ByteReader(try reader.take(reader.remaining - 16))
            let chunk = try chunks.nextChunk()!
            var body = ByteReader(chunk.body)
            Benchmark.blackHole(try receiver.receive(body.fragment(), at: .init()))
            stats.recordArrival(sendTime: header.sendTimeUs, at: .init(1000))
            Benchmark.blackHole(stats.received)
        }
    }
    Benchmark("Allocation assertion wire streams stats", configuration: .init(metrics: [.wallClock], scalingFactor: .kilo)) { benchmark in
        let receiver = Reassembler(maxBytes: 128 * 1024 * 1024)
        var stats = PathStats()
        var packet = datagram
        packet[27] = 0xff
        packet[28] = 0xff
        do {
            var initial = ByteReader(packet.span.bytes)
            _ = try PacketHeader.decode(&initial)
            var chunks = ByteReader(try initial.take(initial.remaining - 16))
            let chunk = try chunks.nextChunk()!
            var body = ByteReader(chunk.body)
            _ = try receiver.receive(body.fragment(), at: .init())
        }
        let iterations = benchmark.scaledIterations
        func pass(offset: Int) throws -> Int? {
            try AllocationCounter.count {
                for index in iterations {
                    let fragmentIndex = index + offset + 1
                    packet[25] = UInt8(truncatingIfNeeded: fragmentIndex >> 8)
                    packet[26] = UInt8(truncatingIfNeeded: fragmentIndex)
                    var reader = ByteReader(packet.span.bytes)
                    let header = try PacketHeader.decode(&reader)
                    var chunks = ByteReader(try reader.take(reader.remaining - 16))
                    let chunk = try chunks.nextChunk()!
                    var body = ByteReader(chunk.body)
                    Benchmark.blackHole(try receiver.receive(body.fragment(), at: .init()))
                    stats.recordArrival(sendTime: header.sendTimeUs, at: .init(1000))
                }
            }
        }
        // Exercise the identical call path before asserting steady-state allocation counts.
        _ = try pass(offset: 0)
        let count = try pass(offset: iterations.count)
        guard let count else { throw WireError.malformed }
        guard count == 0 else { throw AllocationFailure.observed(count) }
    }
    Benchmark("Allocation counter positive control", configuration: .init(metrics: [.wallClock], scalingFactor: .kilo)) { benchmark in
        let count = AllocationCounter.count { for index in benchmark.scaledIterations { Benchmark.blackHole([UInt8](repeating: 1, count: 64 + index % 3)) } }
        guard let count, count >= benchmark.scaledIterations.count else { throw WireError.malformed }
    }
    Benchmark("AES-GCM seal and open 1200 bytes", configuration: .init(metrics: [.wallClock], scalingFactor: .kilo)) { benchmark in
        let protection = try AESGCMProtection(key: .init(repeating: 1, count: 16), iv: .init(repeating: 2, count: 12))
        let header = Array(datagram.prefix(16))
        let plaintext = Array(datagram.dropFirst(32))
        benchmark.startMeasurement()
        for i in benchmark.scaledIterations {
            let sealed = try protection.seal(plaintext, header: header, packetNumber: UInt64(i))
            Benchmark.blackHole(try protection.open(sealed, header: header, packetNumber: UInt64(i)))
        }
    }
    for (name, size) in [("1080p60 20Mbps", 41_666), ("4K60 80Mbps", 166_666), ("500KB IDR", 500_000)] {
        Benchmark("Fragment and reassemble \(name)", configuration: .init(metrics: [.wallClock])) { benchmark in
            let frame = SyntheticFrames.bytes(count: size)
            let fragmenter = try Fragmenter(maxDatagramSize: 1200)
            let receiver = Reassembler()
            var buffer = [UInt8](repeating: 0, count: 1200)
            let count = try fragmenter.fragmentCount(byteCount: size)
            benchmark.startMeasurement()
            for iteration in benchmark.scaledIterations {
                for index in (0..<count).reversed() {
                    let written = try buffer.withUnsafeMutableBytes { raw in
                        var writer = OutputRawSpan(buffer: raw, initializedCount: 0)
                        try frame.withUnsafeBytes { try fragmenter.encode(frame: $0, stream: 1, frameID: UInt32(truncatingIfNeeded: iteration), index: index, into: &writer) }
                        return writer.finalize(for: raw)
                    }
                    var reader = ByteReader(buffer.span.bytes.extracting(0..<written))
                    let chunk = try reader.nextChunk()!
                    var body = ByteReader(chunk.body)
                    Benchmark.blackHole(try receiver.receive(body.fragment(), at: .init()))
                }
            }
        }
    }
    for (name, frameSize) in [("1080p60 20Mbps", 41_666), ("4K60 80Mbps", 166_666)] {
        Benchmark("Full encrypted sans IO frame \(name)", configuration: .init(metrics: [.wallClock])) { benchmark in
            let psk = [UInt8](repeating: 3, count: 32)
            let initiator = try HandshakeInitiator(pairingID: 1, psk: psk)
            let responder = try HandshakeResponder(secret: .init(repeating: 4, count: 32))
            let initial = try initiator.start(configuration: .init(), timestamp: 100)
            let response = try responder.accept(initial, psk: psk, sessionID: 1, timestamp: 100)
            let sender = Connection(result: response.result!, role: .host, peer: .init(port: 2), at: .init())
            let receiver = Connection(result: try initiator.finish(response.packet), role: .client, peer: .init(port: 1), at: .init())
            let bytes = FrameBytes(SyntheticFrames.bytes(count: frameSize))
            benchmark.startMeasurement()
            for iteration in benchmark.scaledIterations {
                let now = Instant(UInt64(iteration) * 16_666_667)
                try sender.submit(.init(stream: 1, storage: bytes, info: SyntheticFrames.info(idr: iteration == 0)), at: now)
                while let packet = sender.pollTransmit(at: now) { receiver.handle(datagram: packet.bytes, from: .init(port: 1), at: now) }
                while let event = receiver.pollEvent() { Benchmark.blackHole(event) }
                receiver.handleTimeout(at: now)
                while let packet = receiver.pollTransmit(at: now) { sender.handle(datagram: packet.bytes, from: .init(port: 2), at: now) }
                while sender.pollEvent() != nil {}
            }
        }
    }

}
