import Foundation
import SpikeCursor
import SpikeProbes
import Synchronization
import Testing

// Runs the probes under Swift Testing so the same code executes on the iOS Simulator
// via `xcodebuild test -scheme Spikes-Package`. Reports go to stdout and to a file.

private func emit(_ r: Report) {
    print(r.text)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("lightray-spikes-\(r.title.prefix(12).filter(\.isLetter)).txt")
    try? r.text.write(to: url, atomically: true, encoding: .utf8)
    print("  [written to \(url.path)]")
}

#if os(iOS)
let platform = "iOS"
#else
let platform = "macOS"
#endif

@Test func stdlibTypesAtRuntime() throws {
    var bits = InlineArray<32, UInt64>(repeating: 0)
    bits[31] = 1 << 63
    let m = Mutex(0)
    m.withLock { $0 += 1 }
    let a = Atomic<UInt64>(0)
    a.add(2, ordering: .relaxed)
    let bytes: [UInt8] = [0, 0, 0, 42, 9]
    var r = ByteReader(bytes.span.bytes)
    #expect(bits[31] == 1 << 63)
    #expect(m.withLock { $0 } == 1)
    #expect(a.load(ordering: .relaxed) == 2)
    #expect(try r.u32() == 42)
    #expect(r.remaining == 1)
    print("[\(platform)] InlineArray / Mutex / Atomic / RawSpan cursor OK")
}

// Serialized: the timing probes would otherwise disturb each other.
@Suite(.serialized) struct Probes {
    @Test func cursor() { emit(cursorProbe(quick: true)) }
    @Test func crypto() { emit(cryptoProbe(quick: true)) }
    @Test func clocks() { emit(clockProbe()) }
    @Test func timers() { emit(timerProbe(quick: true)) }
    @Test func sockets() { emit(socketProbe(quick: true, allowExternalProbe: false)) }
    @Test func throughput() { emit(throughputProbe(quick: true)) }
    @Test func path() { emit(pathProbe()) }
}
