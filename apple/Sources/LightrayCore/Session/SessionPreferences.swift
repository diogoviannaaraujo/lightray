import Foundation

/// Only local presentation and input preferences belong here, never pairing keys or clipboard data.
public struct SessionPreferences: Codable, Equatable, Sendable {
    public var keyboardMapping: RemoteKeyboard.Mapping = .physical
    public var showStatistics = true
    public var localCursor = false
    public init() {}
}

public final class SessionPreferencesStore {
    private struct Record: Codable {
        let version: Int
        let preferences: SessionPreferences
    }
    public enum StoreError: Error { case unsupportedVersion }
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    private func key(_ hostID: UInt64) -> String { "Lightray.session.\(String(hostID, radix: 16))" }

    public func load(hostID: UInt64) throws -> SessionPreferences {
        guard let data = defaults.data(forKey: key(hostID)) else { return SessionPreferences() }
        let record = try JSONDecoder().decode(Record.self, from: data)
        guard record.version == 1 else { throw StoreError.unsupportedVersion }
        return record.preferences
    }

    public func save(_ preferences: SessionPreferences, hostID: UInt64) throws {
        let data = try JSONEncoder().encode(Record(version: 1, preferences: preferences))
        defaults.set(data, forKey: key(hostID))
    }

    public func reset(hostID: UInt64) { defaults.removeObject(forKey: key(hostID)) }
}
