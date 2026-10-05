@testable import LightrayCore

/// A FIFO link with a byte limit, including the packet being transmitted. Overflow drops the
/// arriving packet. Changing the bitrate affects queued traffic on the next advance, too.
final class SimulatedBottleneck {
    struct Transmission {
        let bytes: Bytes
        let from: PeerAddress
        let at: UInt64
    }

    /// Nil is unlimited; zero stops transmission while the finite queue continues accepting traffic.
    var bitrate: Int? {
        didSet { precondition(bitrate == nil || bitrate! >= 0) }
    }
    var queueLimitBytes = 64 << 10
    private(set) var queuedBytes = 0
    private(set) var peakQueuedBytes = 0
    private(set) var droppedDatagrams = 0
    private(set) var transmittedBytes = 0
    private(set) var longestQueueMicros: UInt64 = 0

    private struct Queued {
        let bytes: Bytes
        let from: PeerAddress
        let enqueuedAt: UInt64
    }
    private var queue: [Queued] = []
    private var remainingBytes = 0.0
    private var lastAdvance: UInt64?

    func enqueue(_ bytes: Bytes, from: PeerAddress, now: UInt64) -> [Transmission] {
        if lastAdvance == nil { lastAdvance = now }
        precondition(lastAdvance == now, "advance the path before enqueueing at a later time")
        if bitrate == nil, queue.isEmpty {
            transmittedBytes += bytes.count
            return [Transmission(bytes: bytes, from: from, at: now)]
        }
        guard bytes.count <= queueLimitBytes - queuedBytes else {
            droppedDatagrams += 1
            return []
        }
        if queue.isEmpty { remainingBytes = Double(bytes.count) }
        queue.append(Queued(bytes: bytes, from: from, enqueuedAt: now))
        queuedBytes += bytes.count
        peakQueuedBytes = max(peakQueuedBytes, queuedBytes)
        return []
    }

    func advance(to now: UInt64) -> [Transmission] {
        let start = lastAdvance ?? now
        precondition(now >= start)
        lastAdvance = now
        var time = Double(start)
        var out: [Transmission] = []
        while let packet = queue.first {
            if let bitrate {
                guard bitrate > 0 else { break }
                let rate = Double(bitrate) / 8_000_000 // Bytes per microsecond.
                let duration = remainingBytes / rate
                guard time + duration <= Double(now) else {
                    remainingBytes -= (Double(now) - time) * rate
                    break
                }
                time += duration
            }
            let departed = UInt64(time.rounded(.up))
            out.append(Transmission(bytes: packet.bytes, from: packet.from, at: departed))
            longestQueueMicros = max(longestQueueMicros, departed - packet.enqueuedAt)
            transmittedBytes += packet.bytes.count
            queuedBytes -= packet.bytes.count
            queue.removeFirst()
            remainingBytes = queue.first.map { Double($0.bytes.count) } ?? 0
        }
        return out
    }
}
