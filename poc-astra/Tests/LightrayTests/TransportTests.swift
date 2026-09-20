import Foundation
import Lightray
import LightrayTestSupport
import Synchronization
import Testing

@Test func realUDPLoopbackIPv4AndIPv6() throws {
    let sender = try UDPSocket()
    let receiver = try UDPSocket()
    for host in ["127.0.0.1", "::1"] {
        #expect(try sender.send([1, 2, 3, 4], to: .init(host: host, port: receiver.localPort)))
        var buffer = [UInt8](repeating: 0, count: 1200)
        let deadline = SuspendingClock().now().advanced(by: 100_000_000)
        var received = false
        while SuspendingClock().now() < deadline {
            if let packet = try buffer.withUnsafeMutableBytes({ try receiver.receive(into: $0) }) {
                #expect(packet.count == 4)
                #expect(Array(buffer.prefix(4)) == [1, 2, 3, 4])
                received = true
                break
            }
            Thread.sleep(forTimeInterval: 0.001)
        }
        #expect(received)
    }
}
@Test func runtimeHandshakeFrameAndSocketReplacement() async throws {
    struct State {
        var id: UInt32?
        var frames = 0
        var resumed = false
        var errors: [String] = []
    }
    let state = Mutex(State())
    let psk = [UInt8](repeating: 9, count: 32)
    let host = try LightrayHost(port: 0, pairings: [1: psk], secret: .init(repeating: 8, count: 32)) { id, event in
        state.withLock { value in
            switch event {
            case .connected: value.id = id
            case .resumed: value.resumed = true
            case .error(let error): value.errors.append(error)
            default: break
            }
        }
    }
    let client = try LightrayClient(peer: .init(host: "127.0.0.1", port: host.port), pairingID: 1, psk: psk, monitorPath: false) { _, event in
        state.withLock { value in
            switch event {
            case .frame: value.frames += 1
            case .error(let error): value.errors.append(error)
            default: break
            }
        }
    }
    defer {
        client.stop()
        host.stop()
    }
    for _ in 0..<100 where state.withLock({ $0.id == nil }) { try await Task.sleep(for: .milliseconds(5)) }
    let id = try #require(state.withLock { $0.id })
    host.submit(sessionID: id, bytes: SyntheticFrames.bytes(count: 10_000), info: SyntheticFrames.info(idr: true))
    for _ in 0..<100 where state.withLock({ $0.frames == 0 }) { try await Task.sleep(for: .milliseconds(5)) }
    #expect(state.withLock { $0.frames } == 1)
    let oldPort = client.localPort
    client.park()
    try await Task.sleep(for: .milliseconds(30))
    client.resume()
    for _ in 0..<100 where !state.withLock({ $0.resumed }) { try await Task.sleep(for: .milliseconds(5)) }
    #expect(client.localPort != oldPort)
    #expect(state.withLock { $0.resumed })
    #expect(state.withLock { $0.errors }.isEmpty)
    host.submit(sessionID: id, bytes: [1, 2, 3], info: SyntheticFrames.info(idr: true))
    for _ in 0..<100 where state.withLock({ $0.frames < 2 }) { try await Task.sleep(for: .milliseconds(5)) }
    #expect(state.withLock { $0.frames } == 2)
}
