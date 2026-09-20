import Darwin
import Synchronization

private let allocationCount = Atomic<Int>(0)
private let measuredThread = Atomic<UInt>(0)
private let loggerLock = Mutex(())
@_cdecl("lightray_benchmark_malloc_logger")
func lightrayBenchmarkMallocLogger(_ type: UInt32, _ a1: UInt, _ a2: UInt, _ a3: UInt, _ result: UInt, _ skip: UInt32) { if type & 2 != 0 && UInt(bitPattern: pthread_self()) == measuredThread.load(ordering: .relaxed) { allocationCount.add(1, ordering: .relaxed) } }
enum AllocationCounter {
    typealias Logger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void
    static func count(_ body: () throws -> Void) rethrows -> Int? {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger") else {
            try body()
            return nil
        }
        return try loggerLock.withLock { _ in
            let slot = symbol.assumingMemoryBound(to: Logger?.self)
            let previous = slot.pointee
            measuredThread.store(UInt(bitPattern: pthread_self()), ordering: .relaxed)
            slot.pointee = lightrayBenchmarkMallocLogger
            defer { slot.pointee = previous }
            let before = allocationCount.load(ordering: .relaxed)
            try body()
            return allocationCount.load(ordering: .relaxed) - before
        }
    }
}
