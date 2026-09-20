import Benchmark
import SpikeCursor
import SpikeProbes
#if canImport(Darwin)
import Darwin
#endif

let benchmarks: @Sendable () -> Void = {
    let datagram: [UInt8] = {
        var bytes = [UInt8](repeating: 0x5A, count: 1200)
        bytes.withUnsafeMutableBytes { raw in
            var w = OutputRawSpan(buffer: raw, initializedCount: 0)
            try! PacketHeader(flags: 0, sessionID: 1, transportSeq: 2, sendTimeUs: 3).encode(into: &w)
            try! w.put(UInt8(0x01)); try! w.put(UInt16(14 + 1151))
            try! FragmentHeader(stream: 1, flags: 0, frameID: 7, index: 3, count: 435).encode(into: &w)
            _ = w.finalize(for: raw)
        }
        return bytes
    }()

    Benchmark("parse header + fragment (span cursor)",
              configuration: .init(metrics: [.wallClock, .instructions, .mallocCountTotal], scalingFactor: .kilo)) { benchmark in
        for _ in benchmark.scaledIterations {
            var r = ByteReader(datagram.span.bytes)
            let h = try PacketHeader.decode(&r)
            var body = ByteReader(try r.take(r.remaining - 16))
            while let c = try body.nextChunk() {
                var fr = ByteReader(c.body)
                Benchmark.blackHole(try fr.fragment().header.frameID &+ h.transportSeq)
            }
        }
    }

    // Control: must report ≥ 1 malloc per iteration, or the malloc metric is not real.
    Benchmark("control: allocate an array per iteration",
              configuration: .init(metrics: [.mallocCountTotal], scalingFactor: .kilo)) { benchmark in
        let n = AllocCounter.count {
            for i in benchmark.scaledIterations {
                Benchmark.blackHole([UInt8](repeating: UInt8(truncatingIfNeeded: i), count: 64 + i % 3))
            }
        }
        let line = "malloc_logger saw \(n) allocations for \(benchmark.scaledIterations.count) iterations\n"
        // stdout is swallowed by the benchmark runner; write next to the baselines instead.
        let packageDir = String(#filePath.dropLast("Benchmarks/CursorBenchmarks/CursorBenchmarks.swift".count))
        let f = fopen(packageDir + ".benchmarkBaselines/malloc-check.txt", "a")
        if let f { fputs(line, f); fclose(f) }
    }
}
