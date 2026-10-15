import Foundation
import Testing

@testable import LightrayCore

@Test func connectionTargetsAcceptLANNamesAndIPv6() throws {
    #expect(try ConnectionTarget("  rtx4090:37373  ").address == "rtx4090:37373")
    #expect(try ConnectionTarget("192.168.1.2").port == 7373)
    #expect(try ConnectionTarget("[::1]:37373").host == "::1")
    #expect(try ConnectionTarget("::1").address == "[::1]:7373")
    #expect(try ConnectionTarget("[fe80::1%en0]:123").port == 123)
}

@Test func malformedConnectionTargetsNeverUseADefaultPort() {
    for value in ["", "host:bad", "host:0", "host:65536", "host:", "[::1]bad", "[::1]:", "[host]:123", "two words", "https://host", "::nope", "a..b", "-host", "host\0", "999.1.1.1", "1.2.3.04"] {
        #expect(throws: (any Error).self) { try ConnectionTarget(value) }
    }
}

@Test func pairingStoreRejectsPathsBeforeAccessingDisk() {
    for name in ["", "../outside", "folder/file", "a.b", String(repeating: "a", count: 101)] {
        #expect(throws: PairingStore.StoreError.self) { try PairingStore.read(name) }
        #expect(throws: PairingStore.StoreError.self) { try PairingStore.remove(name) }
    }
}

@Test func hostCatalogPersistsPublicMetadataAndBoundsRecords() throws {
    let suite = "LightrayTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = PairedHostsStore(defaults: defaults)
    let host = PairedHost(pairingID: 1, name: "Lab", address: "rtx4090:37373", displayUUID: UUID().uuidString)
    try store.save([host])
    #expect(try PairedHostsStore(defaults: defaults).load() == [host])
    #expect(host.pairingFileName == "client-host-1")
    #expect(throws: PairedHostsStore.StoreError.self) { try store.save([host, host]) }
    #expect(throws: PairedHostsStore.StoreError.self) { try store.save([PairedHost(pairingID: 1, name: "", address: "host")]) }
    #expect(throws: PairedHostsStore.StoreError.self) { try store.save((0...32).map { PairedHost(pairingID: UInt64($0), name: "Lab", address: "host") }) }
    #expect(throws: PairedHostsStore.StoreError.self) { try store.save([PairedHost(pairingID: 1, name: "Lab", address: "host", displayUUID: "bad")]) }
}

@Test func invalidCatalogVersionsAndDataReportErrors() throws {
    let suite = "LightrayTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = PairedHostsStore(defaults: defaults)
    defaults.set(Data("{\"version\":2,\"hosts\":[]}".utf8), forKey: "Lightray.pairedHosts")
    #expect(throws: PairedHostsStore.StoreError.self) { try store.load() }
    defaults.set(Data("invalid".utf8), forKey: "Lightray.pairedHosts")
    #expect(throws: (any Error).self) { try store.load() }
    defaults.set(Data(repeating: 32, count: 65537), forKey: "Lightray.pairedHosts")
    #expect(throws: PairedHostsStore.StoreError.self) { try store.load() }
}
