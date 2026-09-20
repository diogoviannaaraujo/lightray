import LightrayCore
import Testing

@Suite("Primitives")
struct PrimitiveTests {

    @Test func serialNumbersAreWrapSafe() {
        #expect(serialGreater(5, 3))
        #expect(!serialGreater(3, 5))
        #expect(!serialGreater(4, 4))
        // Across the wrap: 1 is newer than 0xFFFF_FFFF.
        #expect(serialGreater(1, 0xFFFF_FFFF))
        #expect(!serialGreater(0xFFFF_FFFF, 1))
        #expect(serialDistance(1, 0xFFFF_FFFF) == 2)
        #expect(serialGreaterOrEqual(4, 4))
    }

    @Test func packetNumbersReconstructToTheNearestCandidate() {
        // The wire carries 32 bits; the nonce needs all 64.
        #expect(reconstructSequence(truncated: 5, expected: 5) == 5)
        #expect(reconstructSequence(truncated: 1, expected: 0x1_0000_0000) == 0x1_0000_0001)
        // Just past a wrap: the low bits say 2, and the expected value is one
        // short of the boundary, so the answer is on the far side.
        #expect(reconstructSequence(truncated: 2, expected: 0xFFFF_FFFE) == 0x1_0000_0002)
        // A late packet from just before the wrap stays on the near side.
        #expect(reconstructSequence(truncated: 0xFFFF_FFF0, expected: 0x1_0000_0005) == 0xFFFF_FFF0)
    }

    @Test func bitsetFindsClearRuns() {
        var bits = Bitset(capacity: 20)
        for i in [0, 1, 2, 7, 8, 15, 16, 17, 18, 19] { bits[i] = true }
        var runs: [(Int, Int)] = []
        bits.forEachClearRun { runs.append(($0, $1)) }
        // Missing: 3...6, 9...14
        #expect(runs.count == 2)
        #expect(runs[0] == (3, 4))
        #expect(runs[1] == (9, 6))
        #expect(bits.popcount == 10)
        #expect(!bits.isComplete)
        #expect(bits.firstClear() == 3)

        for i in 0..<20 { bits[i] = true }
        #expect(bits.isComplete)
        #expect(bits.firstClear() == nil)
    }

    @Test func testAndSetReportsFirstArrival() {
        var bits = Bitset(capacity: 8)
        let first = bits.testAndSet(3)
        let second = bits.testAndSet(3)
        #expect(first, "first arrival")
        #expect(!second, "a duplicate")
        #expect(bits[3])
    }

    @Test func histogramSummarisesWithoutAllocating() {
        var histogram = Log2Histogram()
        for value in [1, 3, 7, 15, 31, 63, 127, 1000] as [UInt64] { histogram.record(value) }
        #expect(histogram.count == 8)
        #expect(histogram.maxValue == 1000)
        #expect(histogram.mean > 100)
        // Bucket resolution is a factor of two, which is all an overlay needs.
        #expect(histogram.quantile(0.5) > 0)
        #expect(histogram.quantile(1.0) >= 512)
        histogram.clear()
        #expect(histogram.count == 0)
    }

    @Test func rttEstimatorFollowsRFC6298() {
        var rtt = RTTEstimator()
        rtt.record(.milliseconds(10))
        #expect(rtt.smoothed == .milliseconds(10), "the first sample seeds srtt")
        #expect(rtt.minimum == .milliseconds(10))
        for _ in 0..<20 { rtt.record(.milliseconds(20)) }
        #expect(rtt.smoothed > .milliseconds(18) && rtt.smoothed <= .milliseconds(20))
        #expect(rtt.minimum == .milliseconds(10))
        // The RTO is floored, so a fast link does not produce a 1 ms timer.
        #expect(rtt.rto >= .milliseconds(20))
        #expect(rtt.rto <= .seconds(1))
    }

    @Test func ringBufferIsFIFOAndGrows() {
        var ring = RingBuffer<Int>(capacity: 2)
        ring.push(1); ring.push(2); ring.push(3)   // grows past its capacity
        #expect(ring.count == 3)
        #expect(ring.pop() == 1)
        #expect(ring.pop() == 2)
        #expect(ring.pop() == 3)
        #expect(ring.pop() == nil)
    }

    @Test func eventLogKeepsTheNewestEntries() {
        var log = EventLog(capacity: 4)
        for i in 0..<6 {
            log.record(.park, at: Instant(nanos: UInt64(i)), detail: UInt32(i))
        }
        let events = log.events
        #expect(events.count == 4, "a full ring holds its capacity")
        #expect(events.map(\.detail) == [2, 3, 4, 5], "oldest first, newest kept")
        #expect(log.totalRecorded == 6)
    }

    @Test func bufferPoolRecyclesSlabsAndSizeClasses() {
        let pool = BufferPool(slabSize: 2048, maxSlabs: 2)
        let first = pool.takeSlab()
        let second = pool.takeSlab()
        #expect(first != nil && second != nil)
        #expect(pool.takeSlab() == nil, "the cap is backpressure, not a crash")
        pool.giveBack(first!)
        #expect(pool.takeSlab() != nil, "a returned slab is reused")

        // Large buffers round up to a power-of-two class so frames of drifting
        // size reuse the same allocations.
        #expect(BufferPool.sizeClass(for: 5000) == 8192)
        #expect(BufferPool.sizeClass(for: 4096) == 4096)
        let large = pool.takeLarge(5000)
        #expect(large.count == 8192)
        pool.giveBackLarge(large)
        let again = pool.takeLarge(4500)
        #expect(again.count == 8192, "same class, same buffer")
        pool.giveBackLarge(again)
        pool.drain()
        #expect(pool.largeBytesHeld == 0)
    }

    @Test func instantsAreSaturatingAndMonotonic() {
        let a = Instant(nanos: 1_000)
        let b = Instant(nanos: 5_000)
        #expect(b - a == Interval(nanos: 4_000))
        #expect(a - b == .zero, "a clock that appears to go backwards yields zero, not a wrap")
        #expect(a + .microseconds(4) == b)
        #expect(Interval.milliseconds(2).micros == 2_000)
        #expect(Instant(nanos: 2_500_000).microsTruncated == 2_500)
    }
}
