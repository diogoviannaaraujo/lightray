import Foundation
import Testing
import LightrayCore
import LightrayHostSupport

private struct Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    var directory: URL { root.appendingPathComponent("Host", isDirectory: true) }
    var legacy: URL { root.appendingPathComponent("host-pairing") }
    var store: PairedDeviceStore { PairedDeviceStore(directory: directory, legacy: legacy) }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

@Test func waitingCodeWorksUntilItExpires() throws {
    let fixture = Fixture()
    defer { fixture.remove() }
    // The file keeps whole seconds, so this code lasts between 0.5 and 1.5 s.
    let device = try fixture.store.addWaiting(name: " iPad ", lifetime: 1.5)
    #expect(device.name == "iPad" && device.isWaiting)
    let pairings = StoredPairings(store: fixture.store)
    #expect(pairings.key(for: device.id) == device.key)
    #expect(pairings.key(for: device.id &+ 1) == nil)
    Thread.sleep(forTimeInterval: 1.6)
    #expect(pairings.key(for: device.id) == nil)
    // The next change drops the expired code from the file.
    _ = try fixture.store.addWaiting(name: "Mac")
    #expect(try fixture.store.load().map(\.name) == ["Mac"])
    #expect(throws: (any Error).self) { try fixture.store.addWaiting(name: "  ") }
}

@Test func firstConnectionPairsAWaitingDevice() throws {
    let fixture = Fixture()
    defer { fixture.remove() }
    let device = try fixture.store.addWaiting(name: "iPad", lifetime: 60)
    let pairings = StoredPairings(store: fixture.store)
    pairings.connected(device.id)
    pairings.flush()
    let stored = try #require(try fixture.store.load().first)
    #expect(!stored.isWaiting && stored.expires == nil && stored.lastConnected != nil)
    #expect(stored.accepts(at: .distantFuture))
    // Withdrawing a code no longer touches a device that connected with it.
    try fixture.store.removeWaiting(id: device.id)
    #expect(try fixture.store.load().count == 1)
}

@Test func revokedDeviceLosesItsKeyAtTheNextRefresh() throws {
    let fixture = Fixture()
    defer { fixture.remove() }
    let device = try fixture.store.addWaiting(name: "iPad", lifetime: 60)
    try fixture.store.markConnected(id: device.id)
    let pairings = StoredPairings(store: fixture.store)
    #expect(!pairings.refresh())
    #expect(pairings.key(for: device.id) == device.key)
    try fixture.store.remove(id: device.id)
    #expect(pairings.refresh())
    #expect(pairings.key(for: device.id) == nil)
    // A connection recorded after the revocation does not bring the device back.
    pairings.connected(device.id)
    pairings.flush()
    #expect(try fixture.store.load().isEmpty)
}

@Test func earlierSharedCodeIsImportedOnceAndItsFileRemoved() throws {
    let fixture = Fixture()
    defer { fixture.remove() }
    let pairing = Pairing.generate()
    try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
    try Data((pairing.token + "\n").utf8).write(to: fixture.legacy)
    let pairings = StoredPairings(store: fixture.store)
    #expect(pairings.key(for: pairing.id) == pairing.psk)
    let devices = try fixture.store.load()
    #expect(devices.count == 1 && devices[0].shared && !devices[0].isWaiting)
    #expect(devices[0].name == PairedDeviceStore.sharedName)
    #expect(!FileManager.default.fileExists(atPath: fixture.legacy.path))
    #expect(try FileManager.default.attributesOfItem(atPath: fixture.store.url.path)[.posixPermissions] as? Int == 0o600)
    #expect(try FileManager.default.attributesOfItem(atPath: fixture.directory.path)[.posixPermissions] as? Int == 0o700)
    // Revoking it is final: no copy is left to import again.
    try fixture.store.remove(id: pairing.id)
    #expect(try fixture.store.load().isEmpty)
}

@Test func damagedFileAdmitsNoDeviceAndIsPreserved() throws {
    let fixture = Fixture()
    defer { fixture.remove() }
    let device = try fixture.store.addWaiting(name: "iPad", lifetime: 60)
    let pairings = StoredPairings(store: fixture.store)
    try Data("{".utf8).write(to: fixture.store.url)
    #expect(pairings.refresh())
    #expect(pairings.key(for: device.id) == nil)
    #expect(throws: (any Error).self) { try fixture.store.addWaiting(name: "Mac") }
    #expect(try String(contentsOf: fixture.store.url, encoding: .utf8) == "{")
}

@Test func concurrentChangesAreNotLost() throws {
    let fixture = Fixture()
    defer { fixture.remove() }
    DispatchQueue.concurrentPerform(iterations: 20) { index in
        // Separate store values, as separate processes would have.
        _ = try? PairedDeviceStore(directory: fixture.directory, legacy: fixture.legacy).addWaiting(name: "Device \(index)", lifetime: 60)
    }
    #expect(try Set(fixture.store.load().map(\.name)).count == 20)
}
