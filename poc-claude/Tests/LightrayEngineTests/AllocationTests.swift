import Darwin
import Foundation
import LightrayCore
import LightrayCrypto
@testable import LightrayEngine
import LightrayTestSupport
import Synchronization
import Testing

/// Counts allocations through libmalloc's `malloc_logger` hook.
///
/// Phase 0 established that package-benchmark's malloc metric reads 0 without
/// jemalloc even for code that allocates on every iteration, so the
/// zero-allocation target is checked here instead, where the count is real.
///
/// The hook is process-wide, so these tests are serialized and each measurement
/// takes the minimum of several passes: another thread's allocation would
/// otherwise show up as ours.
enum AllocationCounter {
    nonisolated(unsafe) static let total = Atomic<Int>(0)

    typealias Logger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void

    nonisolated(unsafe) static let slot: UnsafeMutablePointer<Logger?>? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger") else { return nil }
        return symbol.assumingMemoryBound(to: Logger?.self)
    }()

    /// Allocations made while `body` runs, or -1 when the hook is unavailable.
    static func count(_ body: () -> Void) -> Int {
        guard let slot else { body(); return -1 }
        slot.pointee = allocationLogger
        let before = total.load(ordering: .relaxed)
        body()
        let after = total.load(ordering: .relaxed)
        slot.pointee = nil
        return after - before
    }

    /// The lowest count over `passes` runs, which filters out another thread's noise.
    static func minimumCount(passes: Int = 5, _ body: () -> Void) -> Int {
        var best = Int.max
        for _ in 0..<passes {
            let count = Self.count(body)
            if count < 0 { return count }
            best = min(best, count)
        }
        return best
    }
}

@_cdecl("lightray_allocation_logger")
func lightrayAllocationLogger(_ type: UInt32, _ a1: UInt, _ a2: UInt, _ a3: UInt,
                              _ result: UInt, _ skip: UInt32) {
    // MALLOC_LOG_TYPE_ALLOCATE
    if type & 2 != 0 { AllocationCounter.total.add(1, ordering: .relaxed) }
}

private let allocationLogger: AllocationCounter.Logger = lightrayAllocationLogger

@Suite("Allocations", .serialized)
struct AllocationTests {

    /// Asserts the zero-allocation target, but only on an optimised build.
    ///
    /// A debug build boxes closures and keeps retain/release traffic that
    /// optimisation removes, so it reports about one allocation per iteration for
    /// code that does not allocate at all. The target is about the shipped code,
    /// so it is checked with `swift test -c release` and merely reported
    /// otherwise.
    static func expectNoAllocations(_ count: Int, _ what: String) {
        #expect(count >= 0, "the malloc_logger hook is unavailable on this build")
        #if DEBUG
        print("[debug build] \(count) allocations for \(what); the target is checked in release")
        #else
        #expect(count == 0, "\(count) allocations for \(what)")
        #endif
    }

    @Test func wireCodecsAllocateNothingPerPacket() {
        let datagram = UnsafeMutableRawBufferPointer.allocate(byteCount: 1200, alignment: 64)
        defer { datagram.deallocate() }
        datagram.initializeMemory(as: UInt8.self, repeating: 0)
        var writer = ByteWriter(datagram)
        try! PacketHeader(sessionID: 1, transportSeq: 2, sendTimeMicros: 3).encode(into: &writer)
        let chunkStart = writer.written
        let site = try! writer.beginChunk(.mediaFragment)
        try! FragmentHeader(stream: 1, flags: [.keyframe], frameID: 7, index: 2, count: 436,
                            stride: 1149).encode(into: &writer)
        try! writer.put([UInt8](repeating: 0x5A, count: 1149))
        writer.endChunk(site)
        let length = writer.written
        let chunkArea = UnsafeRawBufferPointer(rebasing: datagram[chunkStart..<length])
        let out = UnsafeMutableRawBufferPointer.allocate(byteCount: 1200, alignment: 64)
        defer { out.deallocate() }

        let iterations = 20_000
        let allocations = AllocationCounter.minimumCount {
            for i in 0..<iterations {
                // Encode a header and a fragment.
                var w = ByteWriter(out)
                try! PacketHeader(sessionID: 1, transportSeq: UInt32(i), sendTimeMicros: 0)
                    .encode(into: &w)
                let site = try! w.beginChunk(.mediaFragment)
                try! FragmentHeader(stream: 1, flags: [], frameID: UInt32(i), index: 0, count: 1,
                                    stride: 1149).encode(into: &w)
                w.endChunk(site)

                // Decode the header and the fragment.
                let span = RawSpan(_unsafeBytes: chunkArea)
                var r = ByteReader(span)
                if let chunk = try? r.nextChunk() {
                    var body = ByteReader(chunk.body)
                    if let fragment = try? body.fragment() {
                        _ = fragment.header.payloadOffset
                    }
                }
            }
        }
        Self.expectNoAllocations(allocations, "\(iterations) encoded and decoded packets")
    }

    @Test func statsUpdatesAllocateNothing() {
        var path = PathStats()
        var stream = StreamStats()
        var previous: Int64?
        let iterations = 20_000
        let allocations = AllocationCounter.minimumCount {
            for i in 0..<iterations {
                path.packetsReceived &+= 1
                path.bytesReceived &+= 1200
                path.recordTransit(sendMicros: UInt32(i), arrivalMicros: UInt32(i) &+ 2_000,
                                   previous: &previous)
                path.rtt.record(.microseconds(UInt64(2_000 + i % 100)))
                stream.fragmentsReceived &+= 1
                stream.completionLatency.record(UInt64(i % 5_000))
            }
        }
        Self.expectNoAllocations(allocations, "\(iterations) stat updates")
    }

    @Test func replayWindowAndSerialMathAllocateNothing() {
        var window = ReplayWindow()
        let iterations = 20_000
        let allocations = AllocationCounter.minimumCount {
            for i in 0..<iterations {
                _ = window.accept(UInt64(i))
                _ = serialGreater(UInt32(i), UInt32(i &+ 1))
                _ = reconstructSequence(truncated: UInt32(i), expected: UInt64(i))
            }
        }
        Self.expectNoAllocations(allocations, "\(iterations) replay-window updates")
    }

    /// The steady-state receive path: place a fragment into a reassembly buffer.
    /// The slot's buffer and bitset are allocated when the slot opens, never per
    /// packet, so a long frame costs nothing after its first fragment.
    @Test func placingFragmentsAllocatesNothingPerPacket() {
        let pool = BufferPool()
        let reassembler = Reassembler(stream: 1, pool: pool, maxFramesInFlight: 4)
        let payload = [UInt8](repeating: 0x5A, count: 1149)
        let count: UInt16 = 400

        // Open the slot, so the buffer and bitset are already in place.
        payload.withUnsafeBytes { raw in
            let span = RawSpan(_unsafeBytes: raw)
            _ = reassembler.accept(
                FragmentHeader(stream: 1, flags: [], frameID: 1, index: 0, count: count, stride: 1149),
                payload: span, at: .zero, deadline: .seconds(10))
        }

        var index: UInt16 = 1
        let allocations = AllocationCounter.minimumCount(passes: 3) {
            payload.withUnsafeBytes { raw in
                let span = RawSpan(_unsafeBytes: raw)
                for _ in 0..<300 {
                    if index >= count - 1 { index = 1 }
                    _ = reassembler.accept(
                        FragmentHeader(stream: 1, flags: [], frameID: 1, index: index,
                                       count: count, stride: 1149),
                        payload: span, at: .zero, deadline: .seconds(10))
                    index += 1
                }
            }
        }
        // Duplicate arrivals take the cheap path; a first arrival copies bytes.
        // Either way nothing goes to the heap: the slot's buffer and bitset were
        // allocated when the slot opened.
        Self.expectNoAllocations(allocations, "300 fragment placements")
        reassembler.flush()
    }
}
