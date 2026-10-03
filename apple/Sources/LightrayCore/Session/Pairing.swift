import Foundation
import Security

/// A pairing: the identifier a host looks the key up by, and the 32-byte pre-shared key. The
/// protocol leaves pairing to the application; this one passes a token by hand.
public struct Pairing: Equatable, Sendable {
    public let id: UInt64
    public let psk: Bytes

    static let tokenPrefix = "lr1-"

    /// A new pairing from the system's secure random source.
    public static func generate() -> Pairing {
        var bytes = Bytes(repeating: 0, count: 40)
        precondition(SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess)
        return Pairing(id: bytes[0..<8].reduce(0) { $0 << 8 | UInt64($1) }, psk: Array(bytes[8...]))
    }

    public init(id: UInt64, psk: Bytes) {
        precondition(psk.count == 32)
        self.id = id
        self.psk = psk
    }

    /// `lr1-` then the identifier and key in hex.
    public var token: String {
        var w = ByteWriter()
        w.u64(id)
        w.append(psk)
        return Self.tokenPrefix + w.bytes.hex
    }

    public init?(token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(Self.tokenPrefix), let bytes = Bytes(hex: String(trimmed.dropFirst(Self.tokenPrefix.count))),
            bytes.count == 40
        else { return nil }
        self.init(id: bytes[0..<8].reduce(0) { $0 << 8 | UInt64($1) }, psk: Array(bytes[8...]))
    }
}

/// Stores a pairing token in `Lightray/` in Application Support (on iOS, inside the app's
/// container), readable only by the user.
public enum PairingStore {
    public static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lightray", isDirectory: true)
    }

    public static func load(_ name: String) -> Pairing? {
        guard let text = try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8) else { return nil }
        return Pairing(token: text)
    }

    public static func save(_ pairing: Pairing, as name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data((pairing.token + "\n").utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public static func path(_ name: String) -> String { directory.appendingPathComponent(name).path }
}

/// 32 random bytes, for the host's reset-token secret.
public func randomBytes(_ count: Int) -> Bytes {
    var bytes = Bytes(repeating: 0, count: count)
    precondition(SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess)
    return bytes
}
