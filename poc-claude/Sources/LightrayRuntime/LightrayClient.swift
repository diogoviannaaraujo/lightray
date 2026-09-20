import CryptoKit
import Darwin
import LightrayCore
import LightrayCrypto
import LightrayEngine
import Synchronization

/// The client runtime: a `ClientEndpoint` on one kqueue thread, plus the socket
/// replacement a resume needs.
///
/// Safe to hand around for the same reason as `LightrayHost`: commands go in
/// through a mutex, state comes out through one.
public final class LightrayClient: @unchecked Sendable {
    enum Command: Sendable {
        case connect(PeerAddress)
        case reHandshake
        case submit(EncodedFrame)
        case reliable([UInt8], UInt8)
        case park
        case resume(Bool)
        case pathChanged
        case reconfigure(ControlBody)
        case reportDecoded(UInt8, UInt32)
        case close
    }

    private let driver: Driver
    private let loop: EventLoop

    /// The current source port. It changes when a resume replaces the socket,
    /// so it is published by the loop thread rather than read from the socket.
    public var localPort: UInt16 { driver.portBox.withLock { $0 } }
    public var phase: ClientEndpoint.Phase { driver.phaseBox.withLock { $0 } }

    public init(psk: SymmetricKey, pairingID: UInt64, streams: [StreamDescriptor],
                config: SessionConfig, engine: EngineConfig = EngineConfig(),
                capabilities: Capabilities = [.ltr],
                clock: any MonotonicClock = SystemClock.shared,
                onEvent: (@Sendable (ConnectionEvent) -> Void)? = nil) throws {
        let socket = try UDPSocket()
        let endpoint = ClientEndpoint(psk: psk, pairingID: pairingID, streams: streams,
                                      config: config, engine: engine, pool: BufferPool(),
                                      capabilities: capabilities)
        self.driver = Driver(socket: socket, endpoint: endpoint, onEvent: onEvent, at: clock.now())
        self.loop = EventLoop(driver: driver, clock: clock)
        driver.loop = loop
    }

    public func start() { loop.start() }
    public func stop() { loop.stop() }

    public func connect(to host: PeerAddress) { driver.post(.connect(host)) }
    public func connect(host: String, port: UInt16) {
        guard let address = UDPSocket.address(host: host, port: port) else { return }
        driver.post(.connect(address))
    }

    /// Re-handshakes after `.sessionLost`, naming the session in case the host
    /// still has it parked.
    public func reHandshake() { driver.post(.reHandshake) }

    public func submit(_ frame: EncodedFrame) { driver.post(.submit(frame)) }
    public func sendReliable(_ bytes: [UInt8], stream: UInt8 = 0) { driver.post(.reliable(bytes, stream)) }

    /// The app decides what counts as going idle. System sleep is not a park: a
    /// lid close should `close()` and re-handshake on wake.
    public func park() { driver.post(.park) }

    /// Replaces the socket and sends RESUME until STATE comes back.
    public func resume(decoderLost: Bool = false) { driver.post(.resume(decoderLost)) }

    /// Called on a socket error or an `NWPathMonitor` path change.
    public func pathChanged() { driver.post(.pathChanged) }

    public func reconfigure(_ body: ControlBody) { driver.post(.reconfigure(body)) }
    public func reportDecoded(stream: UInt8, frameID: UInt32) { driver.post(.reportDecoded(stream, frameID)) }
    public func close() { driver.post(.close) }

    public func snapshot() -> StatsSnapshot { driver.snapshotBox.withLock { $0 } }

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
        let endpoint: ClientEndpoint
        let onEvent: (@Sendable (ConnectionEvent) -> Void)?
        let pending = Mutex<[Command]>([])
        let snapshotBox = Mutex<StatsSnapshot>(StatsSnapshot())
        let phaseBox = Mutex<ClientEndpoint.Phase>(.idle)
        let portBox: Mutex<UInt16>
        weak var loop: EventLoop?
        private var lastPublish: Instant

        init(socket: UDPSocket, endpoint: ClientEndpoint,
             onEvent: (@Sendable (ConnectionEvent) -> Void)?, at now: Instant) {
            self.socket = socket
            self.endpoint = endpoint
            self.onEvent = onEvent
            self.portBox = Mutex(socket.localPort)
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

        /// A resume needs a new source port, so the host sees a rebind. A socket
        /// that returns an error is replaced for the same reason.
        func replaceSocketIfNeeded() -> Bool {
            guard endpoint.wantsFreshSocket || socket.pendingError != 0 else { return false }
            guard let fresh = try? UDPSocket() else { return false }
            socket.closeSocket()
            socket = fresh
            portBox.withLock { $0 = fresh.localPort }
            endpoint.acknowledgeFreshSocket()
            return true
        }

        func drainCommands(at now: Instant) -> Bool {
            let commands = pending.withLock { list -> [Command] in
                let copy = list
                list.removeAll(keepingCapacity: true)
                return copy
            }
            guard !commands.isEmpty else { return false }
            for command in commands {
                switch command {
                case .connect(let host): endpoint.connect(to: host, at: now)
                case .reHandshake: endpoint.reHandshake(at: now)
                case .submit(let frame): endpoint.submit(frame, at: now)
                case .reliable(let bytes, let stream): endpoint.sendReliable(bytes, stream: stream)
                case .park: endpoint.park(at: now)
                case .resume(let decoderLost): endpoint.resume(decoderLost: decoderLost, at: now)
                case .pathChanged: endpoint.pathChanged(at: now)
                case .reconfigure(let body): _ = endpoint.reconfigure(body)
                case .reportDecoded(let stream, let frameID):
                    endpoint.reportDecoded(stream: stream, frameID: frameID, at: now)
                case .close: endpoint.close(at: now)
                }
            }
            return true
        }

        func publish(at now: Instant) {
            while let event = endpoint.pollEvent() { onEvent?(event) }
            phaseBox.withLock { $0 = endpoint.phase }
            guard now - lastPublish >= .milliseconds(100) else { return }
            lastPublish = now
            let snapshot = endpoint.snapshot()
            snapshotBox.withLock { $0 = snapshot }
        }
    }
}
