import Benchmark
import LightrayCore
import LightrayCrypto
import LightrayEngine
import LightrayTestSupport

// The full sans-IO pipeline, priced per frame. 60 fps is the ceiling: nothing
// above it is a target, so the numbers that matter are the per-frame ones at
// 1080p60/20 Mbps and 4K60/80 Mbps.

let benchmarks: @Sendable () -> Void = {
    Benchmark.defaultConfiguration = .init(
        metrics: [.cpuTotal, .mallocCountTotal, .instructions, .throughput],
        warmupIterations: 5,
        maxDuration: .seconds(3)
    )

    /// One frame all the way from submit to delivered, with feedback coming back.
    func framePipeline(_ name: String, width: UInt16, height: UInt16, bitrate: UInt32,
                       framerate: UInt16, protection: PacketProtection.Mode) {
        Benchmark(name) { benchmark in
            var config = SessionConfig()
            config.bitrate = bitrate
            config.framerate = framerate
            config.width = width
            config.height = height
            let pair = DirectPair(config: config, protection: protection)
            var source = SyntheticFrameSource(stream: 1, bitrate: bitrate, framerate: framerate)
            var now = Instant(nanos: 1_000_000_000)
            let interval = config.frameInterval

            // Warm up past the opening IDR so the measured frames are typical.
            for _ in 0..<3 {
                pair.deliver(source.next(at: now), at: now)
                pair.drainEvents(at: now)
                now = now + interval
            }

            benchmark.startMeasurement()
            for _ in benchmark.scaledIterations {
                blackHole(pair.deliver(source.next(at: now), at: now))
                pair.drainEvents(at: now)
                now = now + interval
            }
            benchmark.stopMeasurement()
        }
    }

    framePipeline("Frame pipeline 1080p60 20 Mbps (AES-GCM)", width: 1920, height: 1080,
                  bitrate: 20_000_000, framerate: 60, protection: .aesGCM)
    framePipeline("Frame pipeline 1080p60 20 Mbps (plaintext)", width: 1920, height: 1080,
                  bitrate: 20_000_000, framerate: 60, protection: .plaintext)
    framePipeline("Frame pipeline 4K60 80 Mbps (AES-GCM)", width: 3840, height: 2160,
                  bitrate: 80_000_000, framerate: 60, protection: .aesGCM)
    framePipeline("Frame pipeline 4K60 80 Mbps (plaintext)", width: 3840, height: 2160,
                  bitrate: 80_000_000, framerate: 60, protection: .plaintext)

    // A 500 KB IDR is the worst case the pacer exists for: 436 fragments at the
    // 1200-byte default.
    Benchmark("500 KB IDR fragment and reassemble (plaintext)") { benchmark in
        for _ in benchmark.scaledIterations {
            let pair = DirectPair(protection: .plaintext)
            var source = SyntheticFrameSource(stream: 1, bitrate: 20_000_000, framerate: 60)
            let now = Instant(nanos: 1_000_000_000)
            let idr = source.next(at: now, forceIDR: true)
            blackHole(pair.deliver(idr, at: now))
            pair.drainEvents(at: now)
        }
    }

}
