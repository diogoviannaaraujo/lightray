import Foundation

/// A shared accounting limit for retained protocol buffers and their metadata, not a process RSS limit.
public final class MemoryBudget: @unchecked Sendable {
    public let limit: Int
    private let lock = NSLock()
    private var used = 0
    private var peak = 0

    public init(limit: Int) {
        precondition(limit >= 0)
        self.limit = limit
    }

    public var usedBytes: Int { lock.withLock { used } }
    public var peakBytes: Int { lock.withLock { peak } }

    private func acquire(_ bytes: Int, keepingFree: Int = 0) -> Bool {
        lock.withLock {
            guard bytes >= 0, keepingFree >= 0, keepingFree <= limit - used, bytes <= limit - used - keepingFree else { return false }
            used += bytes
            peak = max(peak, used)
            return true
        }
    }

    fileprivate func release(_ bytes: Int) {
        lock.withLock {
            precondition(bytes >= 0 && bytes <= used)
            used -= bytes
        }
    }

    func reserve(_ bytes: Int, sharing shared: MemoryBudget? = nil, keepingFree: Int = 0) -> MemoryReservation? {
        guard acquire(bytes, keepingFree: keepingFree) else { return nil }
        var budgets = [self]
        if let shared, shared !== self {
            guard shared.acquire(bytes) else {
                release(bytes)
                return nil
            }
            budgets.append(shared)
        }
        return MemoryReservation(bytes: bytes, budgets: budgets)
    }
}

/// A reservation follows ownership of a buffer, including frames handed to another queue.
final class MemoryReservation: @unchecked Sendable {
    private let bytes: Int
    private let budgets: [MemoryBudget]

    fileprivate init(bytes: Int, budgets: [MemoryBudget]) {
        self.bytes = bytes
        self.budgets = budgets
    }

    deinit { for budget in budgets { budget.release(bytes) } }
}
