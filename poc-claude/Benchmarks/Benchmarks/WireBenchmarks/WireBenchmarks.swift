import Benchmark
import CryptoKit
import LightrayCore
import LightrayCrypto

// The receive path, excluding crypto, has a budget of 250 ns per packet. Phase 0
// measured a header plus fragment parse at 15.8 ns through the span cursor and
// 48 ns including placing the payload, so there is a lot of room.

let benchmarks: @Sendable () -> Void = {
    // Each sample covers 1000 operations. Without that the per-sample harness
    // overhead (about 1.7 µs) swamps a 15 ns parse, and only the instruction
    // count means anything.
    //
    // The malloc metric is reported but cannot be trusted here: Phase 0 found it
    // reads 0 without jemalloc even for code that allocates every iteration.
    // `LightrayCoreTests.AllocationTests` is the real zero-allocation check.
    Benchmark.defaultConfiguration = .init(
        metrics: [.cpuTotal, .instructions, .throughput],
        warmupIterations: 10,
        scalingFactor: .kilo,
        maxDuration: .seconds(2)
    )

    let datagram = UnsafeMutableRawBufferPointer.allocate(byteCount: 1200, alignment: 64)
    datagram.initializeMemory(as: UInt8.self, repeating: 0)
    var writer = ByteWriter(datagram)
    try! PacketHeader(sessionID: 0x1234_5678, transportSeq: 42, sendTimeMicros: 1_000_000)
        .encode(into: &writer)
    let chunkStart = writer.written
    let site = try! writer.beginChunk(.mediaFragment)
    try! FragmentHeader(stream: 1, flags: [.keyframe], frameID: 7, index: 2, count: 436,
                        stride: 1149).encode(into: &writer)
    try! writer.put([UInt8](repeating: 0x5A, count: 1149))
    writer.endChunk(site)
    let datagramLength = writer.written
    let chunkArea = UnsafeRawBufferPointer(rebasing: datagram[chunkStart..<datagramLength])

    Benchmark("Header encode") { benchmark in
        let out = UnsafeMutableRawBufferPointer.allocate(byteCount: 64, alignment: 64)
        defer { out.deallocate() }
        let header = PacketHeader(sessionID: 1, transportSeq: 2, sendTimeMicros: 3)
        for _ in benchmark.scaledIterations {
            var w = ByteWriter(out)
            try! header.encode(into: &w)
            blackHole(w.written)
        }
    }

    Benchmark("Header decode") { benchmark in
        for _ in benchmark.scaledIterations {
            let header = UnsafeRawBufferPointer(rebasing: datagram[..<Wire.headerSize])
            header.withMemoryRebound(to: UInt8.self) { _ in }
            let span = RawSpan(_unsafeBytes: header)
            var r = ByteReader(span)
            blackHole(try! PacketHeader.decode(&r))
        }
    }

    Benchmark("Fragment parse") { benchmark in
        for _ in benchmark.scaledIterations {
            let span = RawSpan(_unsafeBytes: chunkArea)
            var r = ByteReader(span)
            let chunk = try! r.nextChunk()!
            var body = ByteReader(chunk.body)
            let fragment = try! body.fragment()
            blackHole(fragment.header.frameID)
            blackHole(fragment.payload.byteCount)
        }
    }

    // The realistic receive-path unit: parse, then place the payload at
    // index x stride in the reassembly buffer.
    let frameBuffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 436 * 1149, alignment: 64)
    frameBuffer.initializeMemory(as: UInt8.self, repeating: 0)
    Benchmark("Fragment parse and place") { benchmark in
        for _ in benchmark.scaledIterations {
            let span = RawSpan(_unsafeBytes: chunkArea)
            var r = ByteReader(span)
            let chunk = try! r.nextChunk()!
            var body = ByteReader(chunk.body)
            let fragment = try! body.fragment()
            let offset = fragment.header.payloadOffset
            let length = fragment.payload.byteCount
            fragment.payload.withUnsafeBytes { src in
                UnsafeMutableRawBufferPointer(rebasing: frameBuffer[offset..<(offset + length)])
                    .copyMemory(from: src)
            }
            blackHole(offset)
        }
    }

    Benchmark("Feedback encode 200 packets") { benchmark in
        let out = UnsafeMutableRawBufferPointer.allocate(byteCount: 1200, alignment: 64)
        defer { out.deallocate() }
        for _ in benchmark.scaledIterations {
            var w = ByteWriter(out)
            try! Feedback.encode(into: &w, baseSeq: 1000, count: 200) { seq in
                seq % 17 == 0 ? nil : 1_000_000 + (seq - 1000) * 100
            }
            blackHole(w.written)
        }
    }

    Benchmark("Feedback decode 200 packets") { benchmark in
        let out = UnsafeMutableRawBufferPointer.allocate(byteCount: 1200, alignment: 64)
        defer { out.deallocate() }
        var w = ByteWriter(out)
        try! Feedback.encode(into: &w, baseSeq: 1000, count: 200) { seq in
            seq % 17 == 0 ? nil : 1_000_000 + (seq - 1000) * 100
        }
        let encoded = UnsafeRawBufferPointer(rebasing: out[..<w.written])
        for _ in benchmark.scaledIterations {
            let span = RawSpan(_unsafeBytes: encoded)
            var r = ByteReader(span)
            var received = 0
            blackHole(try! Feedback.decode(&r) { _, arrival in if arrival != nil { received += 1 } })
            blackHole(received)
        }
    }

    // Crypto is measured separately because it is the one place that allocates:
    // CryptoKit has no in-place AEAD and CommonCrypto exposes no public GCM, so
    // seal and open always go to the heap.
    let keys = DirectionKeys(SymmetricKey(data: (0..<28).map { UInt8($0) }))
    let protection = PacketProtection(send: keys, receive: keys)
    let header = UnsafeRawBufferPointer(rebasing: datagram[..<Wire.headerSize])
    let plaintext = UnsafeMutableRawBufferPointer.allocate(byteCount: 1168, alignment: 64)
    plaintext.initializeMemory(as: UInt8.self, repeating: 0xAB)
    let sealed = UnsafeMutableRawBufferPointer.allocate(byteCount: 2048, alignment: 64)
    let opened = UnsafeMutableRawBufferPointer.allocate(byteCount: 2048, alignment: 64)
    let sealedLength = protection.seal(plaintext: UnsafeRawBufferPointer(plaintext), header: header,
                                       packetNumber: 1, into: sealed)!
    let sealedView = UnsafeRawBufferPointer(rebasing: sealed[..<sealedLength])

    Benchmark("AES-GCM seal 1168 B") { benchmark in
        for i in benchmark.scaledIterations {
            blackHole(protection.seal(plaintext: UnsafeRawBufferPointer(plaintext), header: header,
                                      packetNumber: UInt64(i), into: sealed))
        }
    }

    Benchmark("AES-GCM open 1168 B") { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(protection.open(sealed: sealedView, header: header, packetNumber: 1, into: opened))
        }
    }

    Benchmark("Plaintext protector 1168 B (crypto-free baseline)") { benchmark in
        let plain = PacketProtection(mode: .plaintext, send: keys, receive: keys)
        for i in benchmark.scaledIterations {
            blackHole(plain.seal(plaintext: UnsafeRawBufferPointer(plaintext), header: header,
                                 packetNumber: UInt64(i), into: sealed))
        }
    }

    Benchmark("Replay window accept") { benchmark in
        var window = ReplayWindow()
        var pn: UInt64 = 1
        for _ in benchmark.scaledIterations {
            pn &+= 1
            blackHole(window.accept(pn))
        }
    }
}
