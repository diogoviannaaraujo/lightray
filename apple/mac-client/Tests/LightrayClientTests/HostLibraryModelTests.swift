import Foundation
import LightrayCore
import XCTest
@testable import lightray_client

@MainActor final class HostLibraryModelTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    private var store: PairedHostsStore!
    private var credentials: [String: Pairing] = [:]
    private var credentialWrites = 0
    private var credentialReads = 0
    private var credentialRemovals = 0
    private let pairing = Pairing(id: 42, psk: Array(repeating: 7, count: 32))
    private let display = LocalDisplay(id: 1, uuid: "54BF6634-A791-482C-9D0B-47D4417F27CA",
                                       name: "Studio Display", maximumFramesPerSecond: 60)

    override func setUp() async throws {
        suite = "LightrayClientTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        store = PairedHostsStore(defaults: defaults)
    }

    override func tearDown() async throws { defaults.removePersistentDomain(forName: suite) }

    private func makeModel(remember: Bool = true) -> HostLibraryModel {
        var options = ClientOptions()
        options.rememberHosts = remember
        let storage = HostLibraryModel.PairingStorage(
            read: { [unowned self] name in
                credentialReads += 1
                guard let pairing = credentials[name] else { throw PairingStore.StoreError.invalidPairing }
                return pairing
            },
            save: { [unowned self] pairing, name in
                credentialWrites += 1
                credentials[name] = pairing
            },
            remove: { [unowned self] name in
                credentialRemovals += 1
                credentials[name] = nil
            })
        let model = HostLibraryModel(options: options, store: store, pairings: storage)
        model.updateDisplays([display])
        return model
    }

    @discardableResult private func addHost(_ model: HostLibraryModel, address: String = "[::1]:37373",
                                             name: String = "") throws -> PairedHost {
        model.addHost(address: address, pairing: pairing)
        model.draft?.name = name
        XCTAssertTrue(model.saveHost(try XCTUnwrap(model.draft)))
        return try XCTUnwrap(model.hosts.first)
    }

    func testAddingHostPersistsMetadataAndRestoresCredentialsAndDisplay() throws {
        let model = makeModel()
        let host = try addHost(model)
        XCTAssertNil(model.draft)
        XCTAssertEqual(host.name, "::1")
        XCTAssertEqual(host.address, "[::1]:37373")
        XCTAssertEqual(host.displayUUID, display.uuid)
        XCTAssertEqual(try store.load(), [host])
        let metadata = try XCTUnwrap(defaults.data(forKey: "Lightray.pairedHosts"))
        XCTAssertFalse(String(decoding: metadata, as: UTF8.self).contains(pairing.token))
        XCTAssertEqual(credentials[host.pairingFileName], pairing)
        let restored = makeModel()
        let connection = try XCTUnwrap(restored.connection(for: host))
        XCTAssertEqual(restored.hosts, [host])
        XCTAssertEqual(connection.target.host, "::1")
        XCTAssertEqual(connection.target.port, 37373)
        XCTAssertEqual(connection.pairing, pairing)
        XCTAssertEqual(connection.displayID, display.id)
    }

    func testInvalidDraftsNeverWriteCredentialsOrCatalog() throws {
        let model = makeModel()
        model.addHost(address: "host:bad", pairing: pairing)
        XCTAssertFalse(model.saveHost(try XCTUnwrap(model.draft)))
        XCTAssertNotNil(model.draft?.error)
        model.draft?.address = "host"
        model.draft?.name = String(repeating: "a", count: 101)
        XCTAssertFalse(model.saveHost(try XCTUnwrap(model.draft)))
        model.draft?.name = "Lab"
        model.draft?.token = "lr1-invalid"
        XCTAssertFalse(model.saveHost(try XCTUnwrap(model.draft)))
        XCTAssertEqual(credentialWrites, 0)
        XCTAssertTrue(try store.load().isEmpty)
        XCTAssertTrue(model.hosts.isEmpty)
    }

    func testEditingUpdatesHostWithoutDuplicatingOrChangingItsIdentity() throws {
        let model = makeModel()
        let host = try addHost(model, name: "Lab")
        model.editHost(host)
        model.draft?.name = "  Workstation  "
        model.draft?.address = "workstation.local"
        XCTAssertTrue(model.saveHost(try XCTUnwrap(model.draft)))
        XCTAssertEqual(model.hosts.count, 1)
        XCTAssertEqual(model.hosts.first?.name, "Workstation")
        XCTAssertEqual(model.hosts.first?.address, "workstation.local:7373")
        model.editHost(try XCTUnwrap(model.hosts.first))
        model.draft?.token = Pairing(id: 43, psk: Array(repeating: 8, count: 32)).token
        XCTAssertFalse(model.saveHost(try XCTUnwrap(model.draft)))
        XCTAssertEqual(model.hosts.first?.pairingID, host.pairingID)
        XCTAssertEqual(credentialWrites, 2)
    }

    func testMissingAndMismatchedCredentialsOpenRepairSheet() throws {
        let model = makeModel()
        let host = try addHost(model)
        credentials[host.pairingFileName] = nil
        XCTAssertNil(model.connection(for: host))
        XCTAssertEqual(model.draft?.editingPairingID, host.pairingID)
        XCTAssertEqual(model.draft?.token, "")
        XCTAssertNotNil(model.draft?.error)
        credentials[host.pairingFileName] = Pairing(id: 43, psk: Array(repeating: 8, count: 32))
        XCTAssertNil(model.connection(for: host))
        XCTAssertEqual(model.draft?.token, "")
        model.draft?.token = pairing.token
        XCTAssertTrue(model.saveHost(try XCTUnwrap(model.draft)))
        XCTAssertEqual(model.connection(for: host)?.pairing, pairing)
    }

    func testDisabledCatalogUsesMemoryWithoutTouchingSavedHostsOrCredentials() throws {
        let saved = PairedHost(pairingID: 99, name: "Existing", address: "saved.local:7373")
        try store.save([saved])
        let model = makeModel(remember: false)
        XCTAssertTrue(model.hosts.isEmpty)
        let host = try addHost(model)
        XCTAssertEqual(model.connection(for: host)?.pairing, pairing)
        model.forgetHost(host)
        XCTAssertTrue(model.hosts.isEmpty)
        XCTAssertEqual(try store.load(), [saved])
        XCTAssertEqual(credentialWrites, 0)
        XCTAssertEqual(credentialReads, 0)
        XCTAssertEqual(credentialRemovals, 0)
    }

    func testUnreadableCatalogIsPreservedWhileTemporaryHostsCanConnect() throws {
        let original = Data("unreadable-catalog".utf8)
        defaults.set(original, forKey: "Lightray.pairedHosts")
        let model = makeModel()
        XCTAssertTrue(model.catalogError)
        XCTAssertFalse(model.canRemember)
        let host = try addHost(model)
        XCTAssertEqual(model.connection(for: host)?.pairing, pairing)
        XCTAssertEqual(defaults.data(forKey: "Lightray.pairedHosts"), original)
        XCTAssertEqual(credentialWrites, 0)
    }

    func testDisplayUUIDSurvivesIDChangesAndDisconnectedDisplaysFallBack() throws {
        let model = makeModel()
        let host = try addHost(model)
        let moved = LocalDisplay(id: 22, uuid: display.uuid, name: display.name, maximumFramesPerSecond: 60)
        model.updateDisplays([moved])
        XCTAssertEqual(model.connection(for: host)?.displayID, moved.id)
        model.editHost(host)
        XCTAssertEqual(model.draft?.displayID, moved.id)
        let fallback = LocalDisplay(id: 33, uuid: UUID().uuidString, name: "Built-in Display", maximumFramesPerSecond: 120)
        model.updateDisplays([fallback])
        XCTAssertEqual(model.draft?.displayID, fallback.id)
        XCTAssertNotNil(model.draft?.error)
        XCTAssertEqual(model.connection(for: host)?.displayID, fallback.id)
        XCTAssertNotNil(model.notice)
    }

    func testForgettingHostRemovesItsCredentialAndPublicRecord() throws {
        let model = makeModel()
        let host = try addHost(model)
        model.forgetHost(host)
        XCTAssertTrue(model.hosts.isEmpty)
        XCTAssertTrue(try store.load().isEmpty)
        XCTAssertNil(credentials[host.pairingFileName])
        XCTAssertEqual(credentialRemovals, 1)
    }

    func testCredentialSaveFailureKeepsDraftAndCatalogUnchanged() throws {
        let model = HostLibraryModel(options: ClientOptions(), store: store, pairings: .init(
            read: { _ in throw PairingStore.StoreError.invalidPairing },
            save: { _, _ in throw CocoaError(.fileWriteNoPermission) },
            remove: { _ in }))
        model.addHost(address: "lab.local", pairing: pairing)
        XCTAssertFalse(model.saveHost(try XCTUnwrap(model.draft)))
        XCTAssertNotNil(model.draft?.error)
        XCTAssertEqual(model.draft?.token, pairing.token)
        XCTAssertTrue(model.hosts.isEmpty)
        XCTAssertTrue(try store.load().isEmpty)
    }
}
