import Darwin
import Foundation
import Synchronization

// MARK: - Report

public struct Report: Sendable {
    public var title: String
    public var lines: [String] = []
    public init(_ title: String) { self.title = title }
    public mutating func add(_ s: String) { lines.append(s) }
    public var text: String { "## \(title)\n" + lines.map { "  " + $0 }.joined(separator: "\n") }
}

// MARK: - Allocation counting via libmalloc's malloc_logger hook (no jemalloc needed)

private let allocCount = Atomic<Int>(0)

@_cdecl("lightray_spike_malloc_logger")
func lightraySpikeMallocLogger(_ type: UInt32, _ a1: UInt, _ a2: UInt, _ a3: UInt, _ result: UInt, _ skip: UInt32) {
    if type & 2 != 0 { allocCount.add(1, ordering: .relaxed) }  // MALLOC_LOG_TYPE_ALLOCATE
}

public enum AllocCounter {
    typealias Fn = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void
    nonisolated(unsafe) static let slot: UnsafeMutablePointer<Fn?>? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger") else { return nil }
        return sym.assumingMemoryBound(to: Fn?.self)
    }()

    /// Allocations made (process-wide) while `body` runs; -1 if the hook is unavailable.
    public static func count(_ body: () throws -> Void) rethrows -> Int {
        guard let slot else { try body(); return -1 }
        slot.pointee = lightraySpikeMallocLogger
        let a = allocCount.load(ordering: .relaxed)
        try body()
        let b = allocCount.load(ordering: .relaxed)
        slot.pointee = nil
        return b - a
    }
}

// MARK: - Timing

@inline(__always) public func nowNs() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

@inline(never) public func blackHole<T>(_ x: T) { withExtendedLifetime(x) {} }

public struct BenchResult: Sendable {
    public var nsPerOp: Double
    public var allocsPerOp: Double
    public var description: String {
        String(format: "%8.1f ns/op  %6.2f allocs/op", nsPerOp, allocsPerOp)
    }
}

/// Best-of-`repeats` ns/op plus allocations/op measured on one extra pass.
public func bench(iterations: Int, repeats: Int = 7, _ body: (Int) throws -> Void) rethrows -> BenchResult {
    for i in 0..<min(iterations, 1000) { try body(i) }  // warm-up
    var best = Double.infinity
    for _ in 0..<repeats {
        let t0 = nowNs()
        for i in 0..<iterations { try body(i) }
        best = min(best, Double(nowNs() - t0) / Double(iterations))
    }
    let allocs = try AllocCounter.count { for i in 0..<iterations { try body(i) } }
    return BenchResult(nsPerOp: best, allocsPerOp: Double(allocs) / Double(iterations))
}

public func cpuTimeNs() -> UInt64 { clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) }

// MARK: - Percentiles

public struct Distribution: Sendable {
    public var sorted: [Double]
    public init(_ xs: [Double]) { sorted = xs.sorted() }
    public func p(_ q: Double) -> Double {
        guard !sorted.isEmpty else { return .nan }
        return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * q + 0.5))]
    }
    public var max: Double { sorted.last ?? .nan }
    public var summary: String {
        String(format: "p50 %7.1f  p90 %7.1f  p99 %7.1f  max %8.1f", p(0.5), p(0.9), p(0.99), max)
    }
}

// MARK: - Threads

/// Runs `body` on a fresh pthread with the given QoS and waits for it.
public func onThread(qos: qos_class_t, _ body: @escaping @Sendable () -> Void) {
    final class Box: @unchecked Sendable { let f: @Sendable () -> Void; init(_ f: @escaping @Sendable () -> Void) { self.f = f } }
    var attr = pthread_attr_t()
    pthread_attr_init(&attr)
    pthread_attr_set_qos_class_np(&attr, qos, 0)
    var tid: pthread_t?
    let ctx = Unmanaged.passRetained(Box(body)).toOpaque()
    let rc = pthread_create(&tid, &attr, { ctx in
        let box = Unmanaged<AnyObject>.fromOpaque(ctx).takeRetainedValue() as! Box
        box.f()
        return nil
    }, ctx)
    precondition(rc == 0)
    pthread_join(tid!, nil)
    pthread_attr_destroy(&attr)
}

/// Starts `body` on a fresh pthread with the given QoS and returns a join handle.
public func spawnThread(qos: qos_class_t, _ body: @escaping @Sendable () -> Void) -> pthread_t {
    final class Box: @unchecked Sendable { let f: @Sendable () -> Void; init(_ f: @escaping @Sendable () -> Void) { self.f = f } }
    var attr = pthread_attr_t()
    pthread_attr_init(&attr)
    pthread_attr_set_qos_class_np(&attr, qos, 0)
    var tid: pthread_t?
    let ctx = Unmanaged.passRetained(Box(body)).toOpaque()
    let rc = pthread_create(&tid, &attr, { ctx in
        let box = Unmanaged<AnyObject>.fromOpaque(ctx).takeRetainedValue() as! Box
        box.f()
        return nil
    }, ctx)
    precondition(rc == 0)
    pthread_attr_destroy(&attr)
    return tid!
}

public func errnoString(_ e: Int32 = errno) -> String { "\(e) \(String(cString: strerror(e)))" }
