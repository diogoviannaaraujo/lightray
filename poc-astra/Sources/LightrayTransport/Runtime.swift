import Darwin
import Foundation
import LightraySession
import Network
import Synchronization

/// One owner thread executes all closures; synchronization protects only the mailbox and snapshots.
public final class EventLoop: @unchecked Sendable {
    private struct Mailbox {
        var commands: [@Sendable () -> Void] = []
        var stopped = false
    }
    private let mailbox = Mutex(Mailbox())
    private let queue: Int32
    private var thread: Thread?
    private let finished = DispatchSemaphore(value: 0)
    public init() throws {
        queue = kqueue()
        guard queue >= 0 else { throw SocketError(operation: "kqueue", code: errno) }
        var events = [kevent(ident: 1, filter: Int16(EVFILT_USER), flags: UInt16(EV_ADD | EV_CLEAR), fflags: 0, data: 0, udata: nil), kevent(ident: 2, filter: Int16(EVFILT_TIMER), flags: UInt16(EV_ADD | EV_ENABLE), fflags: UInt32(NOTE_NSECONDS | NOTE_CRITICAL), data: 1_000_000, udata: nil)]
        guard kevent(queue, &events, 2, nil, 0, nil) >= 0 else {
            let code = errno
            Darwin.close(queue)
            throw SocketError(operation: "kevent register", code: code)
        }
    }
    deinit { Darwin.close(queue) }
    public func register(socket: UDPSocket) throws {
        var event = kevent(ident: UInt(socket.descriptor), filter: Int16(EVFILT_READ), flags: UInt16(EV_ADD | EV_CLEAR), fflags: 0, data: 0, udata: nil)
        guard kevent(queue, &event, 1, nil, 0, nil) >= 0 else { throw SocketError(operation: "kevent socket", code: errno) }
    }
    public func start(tick: @escaping @Sendable () -> Void) {
        precondition(thread == nil)
        let thread = Thread { [self] in
            var events = [Darwin.kevent](repeating: Darwin.kevent(), count: 8)
            while true {
                let result = kevent(queue, nil, 0, &events, Int32(events.count), nil)
                if result < 0 {
                    if errno == EINTR { continue }
                    break
                }
                let (commands, stopped) = mailbox.withLock { state in
                    let commands = state.commands
                    state.commands.removeAll(keepingCapacity: true)
                    return (commands, state.stopped)
                }
                for command in commands { command() }
                if stopped { break }
                tick()
            }
            finished.signal()
        }
        thread.name = "Lightray UDP"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
    }
    public func enqueue(_ command: @escaping @Sendable () -> Void) {
        mailbox.withLock { $0.commands.append(command) }
        wake()
    }
    private func wake() {
        var event = kevent(ident: 1, filter: Int16(EVFILT_USER), flags: 0, fflags: UInt32(NOTE_TRIGGER), data: 0, udata: nil)
        _ = kevent(queue, &event, 1, nil, 0, nil)
    }
    public func stop() {
        mailbox.withLock { $0.stopped = true }
        wake()
        if Thread.current !== thread, thread != nil {
            finished.wait()
            thread = nil
        }
    }
}
/// Thread-confined runtime state. Never expose its endpoint outside the event-loop callback.
private final class RuntimeState: @unchecked Sendable {
    var socket: UDPSocket
    let host: HostEndpoint?
    let client: ClientEndpoint?
    let clock = SuspendingClock()
    let snapshot = Mutex(StatsSnapshot())
    let statsChannel = AsyncStream<StatsSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
    var lastPublish = Instant()
    var recoverSocket: (() throws -> Void)?
    let handler: @Sendable (UInt32, ConnectionEvent) -> Void
    var pending: Transmit?
    var buffer = [UInt8](repeating: 0, count: 9001)
    init(socket: UDPSocket, host: HostEndpoint?, client: ClientEndpoint?, handler: @escaping @Sendable (UInt32, ConnectionEvent) -> Void) {
        self.socket = socket
        self.host = host
        self.client = client
        self.handler = handler
    }
    func connection(_ id: UInt32? = nil) throws -> Connection {
        guard let connection = id.flatMap({ host?.connections[$0] }) ?? client?.connection else { throw WireError.malformed }
        return connection
    }
    func tick() {
        let now = clock.now()
        do {
            for _ in 0..<4096 {
                guard let packet = try buffer.withUnsafeMutableBytes({ try socket.receive(into: $0) }) else { break }
                let bytes = Array(buffer.prefix(packet.count))
                host?.handle(datagram: bytes, from: packet.peer, at: now, timestamp: UInt64(Date().timeIntervalSince1970))
                client?.handle(datagram: bytes, from: packet.peer, at: now)
            }
            host?.handleTimeout(at: now)
            client?.handleTimeout(at: now)
            for _ in 0..<4096 {
                guard let packet = pending ?? host?.pollTransmit(at: now) ?? client?.pollTransmit(at: now) else { break }
                if try socket.send(packet.bytes, to: packet.peer) {
                    pending = nil
                } else {
                    pending = packet
                    break
                }
            }
            while let (id, event) = host?.pollEvent() { handler(id, event) }
            while let event = client?.pollEvent() { handler(client?.connection?.sessionID ?? 0, event) }
            if let stats = client?.connection?.stats ?? host?.connections.values.first?.stats {
                snapshot.withLock { $0 = stats }
                if now.elapsed(since: lastPublish) >= 100_000_000 {
                    statsChannel.continuation.yield(stats)
                    lastPublish = now
                }
            }
        } catch {
            handler(0, .error(String(describing: error)))
            if error is SocketError { do { try recoverSocket?() } catch { handler(0, .error("Socket replacement: \(error)")) } }
        }
    }
}
public final class LightrayHost: @unchecked Sendable {
    private let loop: EventLoop
    private let runtime: RuntimeState
    public let port: UInt16
    public var stats: StatsSnapshot { runtime.snapshot.withLock { $0 } }
    public var snapshots: AsyncStream<StatsSnapshot> { runtime.statsChannel.stream }
    public init(port: UInt16 = 47000, pairings: [UInt64: [UInt8]], secret: [UInt8], onEvent: @escaping @Sendable (UInt32, ConnectionEvent) -> Void = { _, _ in }) throws {
        let socket = try UDPSocket(port: port)
        self.port = socket.localPort
        runtime = try RuntimeState(socket: socket, host: HostEndpoint(pairings: pairings, secret: secret), client: nil, handler: onEvent)
        loop = try EventLoop()
        try loop.register(socket: socket)
        let runtime = runtime
        loop.start { runtime.tick() }
    }
    deinit { loop.stop() }
    public func stop() {
        loop.stop()
        runtime.statsChannel.continuation.finish()
    }
    public func submit(sessionID: UInt32, stream: UInt8 = 1, bytes: [UInt8], info: FrameInfo) {
        let runtime = runtime
        loop.enqueue { do { _ = try runtime.connection(sessionID).submit(.init(stream: stream, storage: FrameBytes(bytes), info: info), at: runtime.clock.now()) } catch { runtime.handler(sessionID, .error(String(describing: error))) } }
    }
    public func sendReliable(sessionID: UInt32, stream: UInt8 = 5, bytes: [UInt8]) {
        let runtime = runtime
        loop.enqueue { do { try runtime.connection(sessionID).sendReliable(stream: stream, bytes: bytes, at: runtime.clock.now()) } catch { runtime.handler(sessionID, .error(String(describing: error))) } }
    }
    public func systemSleep() {
        let runtime = runtime
        loop.enqueue { runtime.host?.systemSleep(at: runtime.clock.now()) }
    }

}
public final class LightrayClient: @unchecked Sendable {
    private let loop: EventLoop
    private let runtime: RuntimeState
    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "Lightray path")
    private let portValue: Mutex<UInt16>
    public var localPort: UInt16 { portValue.withLock { $0 } }
    public var stats: StatsSnapshot { runtime.snapshot.withLock { $0 } }
    public var snapshots: AsyncStream<StatsSnapshot> { runtime.statsChannel.stream }
    public init(peer: PeerAddress, pairingID: UInt64, psk: [UInt8], configuration: Configuration = .init(), monitorPath: Bool = true, onEvent: @escaping @Sendable (UInt32, ConnectionEvent) -> Void = { _, _ in }) throws {
        let socket = try UDPSocket()
        portValue = Mutex(socket.localPort)
        let endpoint = ClientEndpoint(peer: peer, pairingID: pairingID, psk: psk)
        try endpoint.connect(configuration: configuration, at: SuspendingClock().now(), timestamp: UInt64(Date().timeIntervalSince1970))
        runtime = RuntimeState(socket: socket, host: nil, client: endpoint, handler: onEvent)
        loop = try EventLoop()
        try loop.register(socket: socket)
        let runtime = runtime
        loop.start { runtime.tick() }
        let loop = loop
        runtime.recoverSocket = { [weak runtime, weak loop] in
            guard let runtime, let loop else { return }
            let socket = try UDPSocket()
            try loop.register(socket: socket)
            runtime.socket = socket
            runtime.pending = nil
            try runtime.client?.connection?.resume(decoderLost: false, at: runtime.clock.now())
        }
        if monitorPath {
            let initial = Mutex(true)
            monitor.pathUpdateHandler = { [weak self] path in
                let first = initial.withLock {
                    let value = $0
                    $0 = false
                    return value
                }
                if !first && path.status == .satisfied { self?.resume(decoderLost: false) }
            }
            monitor.start(queue: monitorQueue)
        }
    }
    deinit {
        monitor.cancel()
        loop.stop()
    }
    public func stop() {
        monitor.cancel()
        loop.stop()
        runtime.statsChannel.continuation.finish()
    }
    public func park() {
        let runtime = runtime
        loop.enqueue { do { try runtime.client?.connection?.park(at: runtime.clock.now()) } catch { runtime.handler(0, .error(String(describing: error))) } }
    }
    public func resume(decoderLost: Bool = true) {
        let runtime = runtime
        let loop = loop
        loop.enqueue { [weak self] in
            do {
                let socket = try UDPSocket()
                try loop.register(socket: socket)
                runtime.socket = socket
                self?.portValue.withLock { $0 = socket.localPort }
                runtime.pending = nil
                try runtime.client?.connection?.resume(decoderLost: decoderLost, at: runtime.clock.now())
            } catch { runtime.handler(0, .error(String(describing: error))) }
        }
    }
    public func reconfigure(_ configuration: Configuration) {
        let runtime = runtime
        loop.enqueue { do { try runtime.client?.connection?.reconfigure(configuration, at: runtime.clock.now()) } catch { runtime.handler(0, .error(String(describing: error))) } }
    }
    public func connect(configuration: Configuration = .init()) {
        let runtime = runtime
        loop.enqueue { do { try runtime.client?.connect(configuration: configuration, at: runtime.clock.now(), timestamp: UInt64(Date().timeIntervalSince1970)) } catch { runtime.handler(0, .error(String(describing: error))) } }
    }
    public func submit(stream: UInt8, bytes: [UInt8], info: FrameInfo) {
        let runtime = runtime
        loop.enqueue { do { _ = try runtime.connection().submit(.init(stream: stream, storage: FrameBytes(bytes), info: info), at: runtime.clock.now()) } catch { runtime.handler(0, .error(String(describing: error))) } }
    }
    public func sendReliable(stream: UInt8 = 5, bytes: [UInt8]) {
        let runtime = runtime
        loop.enqueue { do { try runtime.connection().sendReliable(stream: stream, bytes: bytes, at: runtime.clock.now()) } catch { runtime.handler(0, .error(String(describing: error))) } }
    }
    public func reportDecoded(stream: UInt8, frameID: UInt32) {
        let runtime = runtime
        loop.enqueue { do { try runtime.connection().reportDecoded(stream: stream, frameID: frameID, at: runtime.clock.now()) } catch { runtime.handler(0, .error(String(describing: error))) } }
    }
    public func systemSleep() {
        let runtime = runtime
        loop.enqueue { do { try runtime.client?.connection?.close(at: runtime.clock.now()) } catch { runtime.handler(0, .error(String(describing: error))) } }
    }

}
