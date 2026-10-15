import Foundation
import Testing
import LightrayHostSupport

@Test func legacySettingsMigrateOnceWithoutEnablingSharing() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let suite = "LightrayHostTests-\(UUID().uuidString)"
    let legacy = try #require(UserDefaults(suiteName: suite))
    defer { legacy.removePersistentDomain(forName: suite) }
    legacy.set(17373, forKey: "sharing.port")
    legacy.set("native", forKey: "sharing.quality")
    legacy.set(false, forKey: "sharing.input")
    let store = HostSettingsStore(directory: directory)
    let migrated = try store.loadOrMigrate(legacy: legacy)
    #expect(!migrated.enabled)
    #expect(migrated.port == 17373)
    #expect(migrated.quality == .native)
    #expect(!migrated.allowInput)
    legacy.set(7373, forKey: "sharing.port")
    #expect(try store.loadOrMigrate(legacy: legacy) == migrated)
    #expect(try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? Int == 0o600)
    #expect(try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int == 0o700)
}

@Test func invalidSettingsArePreserved() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = HostSettingsStore(directory: directory)
    try store.save(HostSettings())
    let invalid = Data("{\"version\":42}".utf8)
    try invalid.write(to: store.url)
    #expect(throws: (any Error).self) { try store.loadOrMigrate() }
    #expect(try Data(contentsOf: store.url) == invalid)
}
