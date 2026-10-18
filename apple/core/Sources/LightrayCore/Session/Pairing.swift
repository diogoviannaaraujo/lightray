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

/// What a host's pairing QR code carries: where to reach the host, what to call it, and the
/// pairing, as `lightray://pair?address=…&name=…&code=lr1-…`. Only Lightray's own scanner reads
/// it: no app registers the scheme, so the system never hands the code to another app.
public struct PairingInvite: Equatable, Sendable {
    public let address: String
    public let name: String
    public let pairing: Pairing

    static let maximumLength = 1024
    private static let unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")

    public init(address: String, name: String, pairing: Pairing) {
        self.address = address
        self.name = name
        self.pairing = pairing
    }

    public var string: String {
        // Everything but unreserved characters is escaped, so a name holding & or = stays one value.
        let escape = { (value: String) in value.addingPercentEncoding(withAllowedCharacters: Self.unreserved)! }
        return "lightray://pair?address=\(escape(address))&name=\(escape(name))&code=\(pairing.token)"
    }

    /// Unknown parameters are ignored; a repeated one, or text over 1 KiB, is refused.
    public init?(string: String) {
        guard string.utf8.count <= Self.maximumLength, let components = URLComponents(string: string),
            components.scheme == "lightray", components.host == "pair", let items = components.queryItems
        else { return nil }
        var values: [String: String] = [:]
        for item in items where ["address", "name", "code"].contains(item.name) {
            guard values[item.name] == nil, let value = item.value else { return nil }
            values[item.name] = value
        }
        let printable = { (value: String) in value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) } }
        guard let address = values["address"], !address.isEmpty, address.count <= 255, printable(address),
            !address.contains(where: \.isWhitespace),
            let code = values["code"], let pairing = Pairing(token: code)
        else { return nil }
        let name = values["name"] ?? ""
        guard name.count <= 100, printable(name) else { return nil }
        self.init(address: address, name: name, pairing: pairing)
    }
}

/// Stores a pairing token in `Lightray/` in Application Support (on iOS, inside the app's
/// container), readable only by the user.
public enum PairingStore {
    public enum StoreError: Error { case invalidName, invalidPairing }
    private static func namedURL(_ name: String) throws -> URL {
        guard !name.isEmpty, name.utf8.count <= 100, name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { throw StoreError.invalidName }
        return directory.appendingPathComponent(name)
    }
    public static func read(_ name: String) throws -> Pairing {
        let text = try String(contentsOf: namedURL(name), encoding: .utf8)
        guard let pairing = Pairing(token: text) else { throw StoreError.invalidPairing }
        return pairing
    }
    public static func remove(_ name: String) throws {
        let url = try namedURL(name)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
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
        let url = try namedURL(name)
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
