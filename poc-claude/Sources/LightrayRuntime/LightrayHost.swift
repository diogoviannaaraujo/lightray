import CryptoKit
import Darwin
import LightrayCore
import LightrayCrypto
import LightrayEngine
import Synchronization

/// The host runtime: a `HostEndpoint` on one kqueue thread.
///
/// The public API posts commands to the loop rather than touching the engine, so
/// the engine stays single-threaded and needs no locks of its own. That is also
/// what makes this type safe to hand around: every public member either posts to
/// a mutex-protected queue or reads a mutex-protected snapshot.
public final class LightrayHost: @unchecked Sendable {
    enum Command: Sendable {
        case submit(EncodedFrame, UInt32?)          // nil session: every session
        case park(UInt32)
        case reportDecoded(UInt32, UInt8, UInt32)
        case reconfigure(UInt32, ControlBody)
        case close(UInt32, CloseCode)
    }

    private let driver: Driver
    private let loop: EventLoop
    private let clock: any MonotonicClock

    /// The bound port. The host never replaces its socket, so this is stable.
    public let localPort: UInt16

    public init(psk: SymmetricKey, streams: [StreamDescriptor], config: SessionConfig,
                engine: EngineConfig = EngineConfig(), port: UInt16 = 0,
                clock: any MonotonicClock = SystemClock.shared,
                onEvent: (@Sendable (HostEndpoint.Event) -> Void)? = nil) throws {
        let socket = try UDPSocket(port: port)
        self.localPort = socket.localPort
        self.clock = clock
        let now = clock.now()
        self.driver = Driver(socket: socket,
                             endpoint: HostEndpoint(psk: psk, streams: streams, config: config,
                                                    engine: engine, pool: BufferPool(),
                                                    at: now),
                             onEvent: onEvent, at: now)
        self.loop = EventLoop(driver: driver, clock: clock)
        driver.loop = loop
    }

    public func start() { loop.start() }
    public func stop() { loop.stop() }

    /// Submits a frame to one session, or to every session when `sessionID` is nil.
    public func submit(_ frame: EncodedFrame, to sessionID: UInt32? = nil) {
        driver.post(.submit(frame, sessionID))
    }

    public func park(sessionID: UInt32) { driver.post(.park(sessionID)) }

    public func reportDecoded(sessionID: UInt32, stream: UInt8, frameID: UInt32) {
        driver.post(.reportDecoded(sessionID, stream, frameID))
    }

    public func reconfigure(sessionID: UInt32, _ body: ControlBody) {
        driver.post(.reconfigure(sessionID, body))
    }

    public func close(sessionID: UInt32, code: CloseCode = .appRequest) {
        driver.post(.close(sessionID, code))
    }

    /// The most recent published snapshot per session, refreshed at up to 10 Hz.
    public func snapshots() -> [UInt32: StatsSnapshot] { driver.snapshots.withLock { $0 } }

    public var loopStats: (iterations: UInt64, received: UInt64, sent: UInt64, sendErrors: UInt64, cpuNanos: UInt64) {
        (loop.loopIterations, loop.datagramsReceived, loop.datagramsSent, loop.sendErrors, loop.loopCPUNanos)
    }

    /// Loop-thread CPU by phase, in nanoseconds: the kqueue wait, draining the
    /// socket, timers and commands, transmitting, and publishing events.
    public var loopCPUBreakdown: (wait: UInt64, receive: UInt64, timers: UInt64,
                                  transmit: UInt64, publish: UInt64) {
        loop.cpuBreakdown
    }

    // MARK: - Driver

    final class Driver: LoopDriver, @unchecked Sendable {
        var socket: UDPSocket
        let endpoint: HostEndpoint
        let onEvent: (@Sendable (HostEndpoint.Event) -> Void)?
        let pending = Mutex<[Command]>([])
        let snapshots = Mutex<[UInt32: StatsSnapshot]>([:])
        weak var loop: EventLoop?
        private var lastPublish: Instant

        init(socket: UDPSocket, endpoint: HostEndpoint,
             onEvent: (@Sendable (HostEndpoint.Event) -> Void)?, at now: Instant) {
            self.socket = socket
            self.endpoint = endpoint
            self.onEvent = onEvent
            self.lastPublish = now
        }

        func post(_ command: Command) {
            pending.withLock { $0.append(command) }
            loop?.wake()
        }

        func handle(datagram: UnsafeRawBufferPointer, from: PeerAddress, at: Instant) {
            endpoint.handle(datagram: datagram, from: from, at: at)
        }

        func handleTimeout(at: Instant) { endpoint.handleTimeout(at: at) }

        func pollTransmit(into buffer: UnsafeMutableRawBufferPointer, at: Instant) -> Outgoing? {
            endpoint.pollTransmit(into: buffer, at: at)
        }

        func nextTimeout(at: Instant) -> Instant? { endpoint.nextTimeout(at: at) }

        func replaceSocketIfNeeded() -> Bool { false }   // only the client rebinds

        func drainCommands(at now: Instant) -> Bool {
            let commands = pending.withLock { list -> [Command] in
                let copy = list
                list.removeAll(keepingCapacity: true)
                return copy
            }
            guard !commands.isEmpty else { return false }
            for command in commands {
                switch command {
                case .submit(let frame, let sessionID):
                    if let id = sessionID {
                        endpoint.connection(id)?.submit(frame, at: now)
                    } else {
                        for id in endpoint.activeSessionIDs { endpoint.connection(id)?.submit(frame, at: now) }
                    }
                case .park(let id):
                    endpoint.connection(id)?.park(at: now)
                case .reportDecoded(let id, let stream, let frameID):
                    endpoint.connection(id)?.reportDecoded(stream: stream, frameID: frameID, at: now)
                case .reconfigure(let id, let body):
                    endpoint.connection(id)?.reconfigure(body)
                case .close(let id, let code):
                    endpoint.connection(id)?.close(code: code, at: now)
                }
            }
            return true
        }

        /// Hands events to the app on the loop thread, and republishes stats at
        /// no more than 10 Hz.
        func publish(at now: Instant) {
            while let event = endpoint.pollEvent() { onEvent?(event) }
            guard now - lastPublish >= .milliseconds(100) else { return }
            lastPublish = now
            var all: [UInt32: StatsSnapshot] = [:]
            for id in endpoint.activeSessionIDs {
                if let snapshot = endpoint.connection(id)?.snapshot() { all[id] = snapshot }
            }
            snapshots.withLock { $0 = all }
        }
    }
}
