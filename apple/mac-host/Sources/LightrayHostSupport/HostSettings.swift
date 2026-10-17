import Foundation
import LightrayCore

public enum HostQuality: String, Codable, CaseIterable, Sendable {
    case balanced, smooth, native
    public var title: String {
        switch self {
        case .balanced: return "Balanced · 30 fps · half resolution"
        case .smooth: return "Smooth · 60 fps · half resolution"
        case .native: return "Native resolution · 60 fps"
        }
    }
    public var frameRate: Int { self == .balanced ? 30 : 60 }
    public var scale: Double { self == .native ? 1 : 0.5 }
}

public enum HostFailure: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}

public struct HostSettings: Codable, Equatable, Sendable {
    public var version = 1
    public var enabled = false
    public var port: UInt16 = 7373
    public var quality: HostQuality = .balanced
    public var allowInput = true
    public var registeredBuild: String?
    public init() {}
    public func validate() throws {
        guard version == 1 else { throw HostFailure.message("Unsupported host settings version. The file was preserved.") }
        guard port > 0 else { throw HostFailure.message("Enter a port between 1 and 65535.") }
    }
}

public struct HostSettingsStore: Sendable {
    public let directory: URL
    public var url: URL { directory.appendingPathComponent("settings.json") }
    public init(directory: URL = PairingStore.directory.appendingPathComponent("Host", isDirectory: true)) {
        self.directory = directory
    }
    public func load() throws -> HostSettings {
        let value = try JSONDecoder().decode(HostSettings.self, from: Data(contentsOf: url))
        try value.validate()
        return value
    }
    /// Migration runs only in the settings app. Never infers consent to automatic sharing.
    public func loadOrMigrate(legacy: UserDefaults? = UserDefaults(suiteName: "io.lightray.mac")) throws -> HostSettings {
        if FileManager.default.fileExists(atPath: url.path) { return try load() }
        var value = HostSettings()
        if let port = legacy?.integer(forKey: "sharing.port"), (1...65535).contains(port) { value.port = UInt16(port) }
        if let name = legacy?.string(forKey: "sharing.quality"), let quality = HostQuality(rawValue: name) { value.quality = quality }
        if legacy?.object(forKey: "sharing.input") != nil { value.allowInput = legacy!.bool(forKey: "sharing.input") }
        try save(value)
        return value
    }
    public func save(_ value: HostSettings) throws {
        try value.validate()
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let data = try JSONEncoder().encode(value)
        try data.write(to: url, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

public enum HostIdentity {
    public static let app = "com.getlightray.host"
    public static let service = "com.getlightray.host.service"
    public static let plist = service + ".plist"
    public static let helperPath = "Contents/Library/LoginItems/LightrayHostService.app"
    public static var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Lightray/host.log")
    }
    public static func parentApp(of helper: URL) -> URL {
        (0..<4).reduce(helper) { url, _ in url.deletingLastPathComponent() }
    }
}
