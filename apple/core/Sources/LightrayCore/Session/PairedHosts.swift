import Foundation

/// Public connection metadata only. Pairing material remains in PairingStore's protected files.
public struct PairedHost: Codable, Equatable, Sendable {
    public let pairingID: UInt64
    public var name: String
    public var address: String
    public var displayUUID: String?
    public var pairingFileName: String { "client-host-\(String(pairingID, radix: 16))" }
    public init(pairingID: UInt64, name: String, address: String, displayUUID: String? = nil) {
        self.pairingID = pairingID; self.name = name; self.address = address; self.displayUUID = displayUUID
    }
}

public final class PairedHostsStore {
    private struct Record: Codable { let version: Int; let hosts: [PairedHost] }
    public enum StoreError: Error { case unsupportedVersion, invalidRecord }
    private let defaults: UserDefaults
    public static let maximumHosts = 32
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func load() throws -> [PairedHost] {
        guard let data = defaults.data(forKey: "Lightray.pairedHosts") else { return [] }
        guard data.count <= 65536 else { throw StoreError.invalidRecord }
        let record = try JSONDecoder().decode(Record.self, from: data)
        guard record.version == 1 else { throw StoreError.unsupportedVersion }
        try validate(record.hosts)
        return record.hosts
    }
    public func save(_ hosts: [PairedHost]) throws {
        try validate(hosts)
        defaults.set(try JSONEncoder().encode(Record(version: 1, hosts: hosts)), forKey: "Lightray.pairedHosts")
    }
    public func validate(_ hosts: [PairedHost]) throws {
        guard hosts.count <= Self.maximumHosts, Set(hosts.map(\.pairingID)).count == hosts.count else { throw StoreError.invalidRecord }
        for host in hosts {
            guard !host.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, host.name.utf8.count <= 100, !host.name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw StoreError.invalidRecord }
            _ = try ConnectionTarget(host.address)
            if let uuid = host.displayUUID, UUID(uuidString: uuid) == nil { throw StoreError.invalidRecord }
        }
    }
}
