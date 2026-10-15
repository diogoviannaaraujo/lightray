import Foundation
import Testing
import LightrayCore
@testable import LightrayHostRuntime

@Test func runtimeStopReleasesPortAndDoesNotExitProcess() async throws {
    let probe = try UDPSocket(port: 0, queue: DispatchQueue(label: "lifecycle.probe"))
    let port = probe.localPort
    probe.close()
    var options = HostOptions()
    options.port = port; options.testPattern = (320, 240); options.inputMode = .off; options.warmSeconds = 0
    let host = HostApp(options: options, pairing: .generate())
    try await host.run()
    await host.stop()
    await host.stop()
    let rebound = try UDPSocket(port: port, queue: DispatchQueue(label: "lifecycle.rebound"))
    rebound.close()
}

@Test func failedRuntimeStartupCanBeStopped() async throws {
    let occupied = try UDPSocket(port: 0, queue: DispatchQueue(label: "lifecycle.occupied"))
    defer { occupied.close() }
    var options = HostOptions()
    options.port = occupied.localPort; options.testPattern = (320, 240); options.inputMode = .off
    let host = HostApp(options: options, pairing: .generate())
    await #expect(throws: (any Error).self) { try await host.run() }
    await host.stop()
}
