import Foundation
import LightrayCore
import Security

/// Keeps pairing keys in this app's local Keychain. Host names and addresses live separately.
enum PairingVault {
    enum VaultError: LocalizedError {
        case keychain(operation: String, status: OSStatus)
        case invalidKey

        var errorDescription: String? {
            switch self {
            case .keychain(let operation, let status):
                let reason = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown Keychain error"
                return "Could not \(operation) the pairing key: \(reason) (\(status))."
            case .invalidKey:
                return "The saved pairing key is invalid. Pair this computer again."
            }
        }
    }

    static func save(_ pairing: Pairing) throws {
        let query = itemQuery(id: pairing.id)
        let attributes: [String: Any] = [
            kSecValueData as String: Data(pairing.psk),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let item = query.merging(attributes) { _, new in new }
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw VaultError.keychain(operation: "save", status: status)
        }
    }

    static func load(id: UInt64) throws -> Pairing {
        var query = itemQuery(id: id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            throw VaultError.keychain(operation: "load", status: status)
        }
        guard let key = result as? Data, key.count == 32 else {
            throw VaultError.invalidKey
        }
        return Pairing(id: id, psk: Array(key))
    }

    static func remove(id: UInt64) throws {
        let status = SecItemDelete(itemQuery(id: id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw VaultError.keychain(operation: "remove", status: status)
        }
    }

    private static func itemQuery(id: UInt64) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.lightray.ipad.pairing",
            kSecAttrAccount as String: String(id, radix: 16),
            kSecAttrSynchronizable as String: false,
        ]
    }
}
