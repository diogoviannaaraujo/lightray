import Darwin
import LightrayCore
import LightrayEngine
import Synchronization

/// What the loop drives. Both runtimes implement it over their endpoint.
protocol LoopDriver: AnyObject {
    func handle(datagram: UnsafeRawBufferPointer, from: PeerAddress, at: Instant)
    func handleTimeout(at: Instant)
    func pollTransmit(into: UnsafeMutableRawBufferPointer, at: Instant) -> Outgoing?
    func nextTimeout(at: Instant) -> Instant?
    /// Applies commands posted from other threads.
    func drainCommands(at: Instant) -> Bool
    /// Hands engine events to the app.
    func publish(at: Instant)
    /// The socket to read from and write to, which the client may replace.
    var socket: UDPSocket { get }
    /// True when the driver wants its socket replaced before the next send.
    func replaceSocketIfNeeded() -> Bool
}

/// One kqueue thread per endpoint.
///
/// `start()` and `stop()` are called by the owning thread; everything else
/// crosses the boundary through the driver's mutex-protected command queue or
/// through atomics.
///
/// Timer precision matters here: Phase 0 measured a plain `kevent` timeout waking
/// about 25% late and `EVFILT_TIMER` with `NOTE_NSECONDS` about 50% late, with
/// `NOTE_LEEWAY` making no difference. Only `NOTE_CRITICAL` is precise — median
/// 5–30 µs, p99 under about 170 µs — which is what a 1 ms pacer tick needs.
final class EventLoop: @unchecked Sendable {
    private let kq: Int32
    private let driver: any LoopDriver
    private let clock: any MonotonicClock
    private let running = Atomic<Bool>(false)
    private var thread: pthread_t?
    private let wakeIdent: UInt64 = 1
    private let timerIdent: UInt64 = 2
    private var registeredFD: Int32 = -1

    /// Never arm a timer shorter than this: below it the wake cost dominates.
    private let minimumTimer = Interval.microseconds(200)
    /// Wake at least this often, so a driver that forgets to arm a timer still runs.
    private let maximumTimer = Interval.milliseconds(100)

    // Written by the loop thread, read by whoever asks: atomics, not plain
    // counters, because a torn read of a statistic is still a data race.
    private let iterations = Atomic<UInt64>(0)
    private let received = Atomic<UInt64>(0)
    private let sent = Atomic<UInt64>(0)
    private let errors = Atomic<UInt64>(0)
    private let cpuNanos = Atomic<UInt64>(0)

    var loopIterations: UInt64 { iterations.load(ordering: .relaxed) }
    var datagramsReceived: UInt64 { received.load(ordering: .relaxed) }
    var datagramsSent: UInt64 { sent.load(ordering: .relaxed) }
    var sendErrors: UInt64 { errors.load(ordering: .relaxed) }
    var loopCPUNanos: UInt64 { cpuNanos.load(ordering: .relaxed) }

    // Where the loop thread's CPU goes, so a cost can be attributed instead of
    // guessed at. Each phase is timed with two clock reads, about 14 ns against
    // the tens of microseconds a turn actually takes.
    private let waitCPU = Atomic<UInt64>(0)
    private let receiveCPU = Atomic<UInt64>(0)
    private let timerCPU = Atomic<UInt64>(0)
    private let transmitCPU = Atomic<UInt64>(0)
    private let publishCPU = Atomic<UInt64>(0)

    /// Loop-thread CPU by phase, in nanoseconds.
    ///
    /// `CLOCK_THREAD_CPUTIME_ID` costs 72 ns a read on an M4, so ten reads a turn
    /// is under 1 µs against the tens of microseconds a turn takes. Cheap enough
    /// to leave on, and the only way to attribute a cost rather than guess at it.
    var cpuBreakdown: (wait: UInt64, receive: UInt64, timers: UInt64, transmit: UInt64, publish: UInt64) {
        (waitCPU.load(ordering: .relaxed), receiveCPU.load(ordering: .relaxed),
         timerCPU.load(ordering: .relaxed), transmitCPU.load(ordering: .relaxed),
         publishCPU.load(ordering: .relaxed))
    }

    init(driver: any LoopDriver, clock: any MonotonicClock = SystemClock.shared) {
        self.kq = kqueue()
        self.driver = driver
        self.clock = clock
    }

    deinit { close(kq) }

    /// Nudges the loop from another thread.
    ///
    /// `EV_CLEAR` coalesces triggers — Phase 0 saw 7 of 200 merge — so a wake is
    /// not one-to-one with a trigger. The loop therefore drains its whole command
    /// queue on every wake rather than counting them.
    func wake() {
        var trigger = kevent64_s(ident: wakeIdent, filter: Int16(EVFILT_USER), flags: 0,
                                 fflags: UInt32(NOTE_TRIGGER), data: 0, udata: 0, ext: (0, 0))
        _ = kevent64(kq, &trigger, 1, nil, 0, 0, nil)
    }

    func start() {
        guard !running.load(ordering: .acquiring) else { return }
        running.store(true, ordering: .releasing)

        var registration = kevent64_s(ident: wakeIdent, filter: Int16(EVFILT_USER),
                                      flags: UInt16(EV_ADD | EV_CLEAR), fflags: 0, data: 0,
                                      udata: 0, ext: (0, 0))
        _ = kevent64(kq, &registration, 1, nil, 0, 0, nil)
        registerSocket(driver.socket.fd)

        final class Box: @unchecked Sendable {
            let body: () -> Void
            init(_ body: @escaping () -> Void) { self.body = body }
        }
        let box = Box { [self] in run() }
        var attributes = pthread_attr_t()
        pthread_attr_init(&attributes)
        // The loop is the latency-critical thread; everything else can wait.
        pthread_attr_set_qos_class_np(&attributes, QOS_CLASS_USER_INTERACTIVE, 0)
        var tid: pthread_t?
        let context = Unmanaged.passRetained(box).toOpaque()
        let rc = pthread_create(&tid, &attributes, { context in
            let box = Unmanaged<Box>.fromOpaque(context).takeRetainedValue()
            box.body()
            return nil
        }, context)
        precondition(rc == 0, "could not start the loop thread")
        pthread_attr_destroy(&attributes)
        thread = tid
    }

    func stop() {
        guard running.load(ordering: .acquiring) else { return }
        running.store(false, ordering: .releasing)
        wake()
        if let thread { pthread_join(thread, nil) }
        thread = nil
    }

    private func registerSocket(_ fd: Int32) {
        if registeredFD >= 0 {
            var removal = kevent64_s(ident: UInt64(registeredFD), filter: Int16(EVFILT_READ),
                                     flags: UInt16(EV_DELETE), fflags: 0, data: 0, udata: 0, ext: (0, 0))
            _ = kevent64(kq, &removal, 1, nil, 0, 0, nil)
        }
        var registration = kevent64_s(ident: UInt64(fd), filter: Int16(EVFILT_READ),
                                      flags: UInt16(EV_ADD | EV_CLEAR), fflags: 0, data: 0,
                                      udata: 0, ext: (0, 0))
        _ = kevent64(kq, &registration, 1, nil, 0, 0, nil)
        registeredFD = fd
    }

    private func run() {
        let receiveBuffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 4096, alignment: 64)
        let sendBuffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 4096, alignment: 64)
        defer { receiveBuffer.deallocate(); sendBuffer.deallocate() }
        let cpuStart = threadCPUNanos()

        while running.load(ordering: .acquiring) {
            iterations.add(1, ordering: .relaxed)
            var event = kevent64_s()
            let now = clock.now()
            let deadline = timerDeadline(from: now)
            var change = kevent64_s(ident: timerIdent, filter: Int16(EVFILT_TIMER),
                                    flags: UInt16(EV_ADD | EV_ONESHOT),
                                    fflags: UInt32(NOTE_NSECONDS | NOTE_CRITICAL),
                                    data: Int64(deadline.nanos), udata: 0, ext: (0, 0))
            var phase = threadCPUNanos()
            let count = kevent64(kq, &change, 1, &event, 1, 0, nil)
            waitCPU.add(threadCPUNanos() - phase, ordering: .relaxed)
            guard running.load(ordering: .acquiring) else { break }

            var at = clock.now()
            phase = threadCPUNanos()
            if count == 1, event.filter == Int16(EVFILT_READ) {
                // Drain the socket: one readable notification can cover many
                // datagrams, and EV_CLEAR will not tell us again.
                while let (length, from) = driver.socket.receive(into: receiveBuffer) {
                    received.add(1, ordering: .relaxed)
                    at = clock.now()
                    driver.handle(datagram: UnsafeRawBufferPointer(rebasing: receiveBuffer[..<length]),
                                  from: from, at: at)
                }
            }

            receiveCPU.add(threadCPUNanos() - phase, ordering: .relaxed)

            phase = threadCPUNanos()
            _ = driver.drainCommands(at: at)
            driver.handleTimeout(at: at)
            if driver.replaceSocketIfNeeded() { registerSocket(driver.socket.fd) }
            timerCPU.add(threadCPUNanos() - phase, ordering: .relaxed)

            phase = threadCPUNanos()
            while let outgoing = driver.pollTransmit(into: sendBuffer, at: at) {
                let n = driver.socket.send(UnsafeRawBufferPointer(rebasing: sendBuffer[..<outgoing.length]),
                                           to: outgoing.destination)
                if n < 0 { errors.add(1, ordering: .relaxed) } else { sent.add(1, ordering: .relaxed) }
                at = clock.now()
            }
            driver.publish(at: at)
            cpuNanos.store(threadCPUNanos() - cpuStart, ordering: .relaxed)
        }
    }

    private func timerDeadline(from now: Instant) -> Interval {
        guard let next = driver.nextTimeout(at: now) else { return maximumTimer }
        let delta = next > now ? next - now : .zero
        if delta < minimumTimer { return minimumTimer }
        return delta > maximumTimer ? maximumTimer : delta
    }
}
