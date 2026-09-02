import Foundation
import Security

/// Printer administrator passwords live in the login keychain, never in UserDefaults.
enum Keychain {
    /// Namespaced per app, so the user app cannot read the administrator passwords the
    /// fleet manager saves, nor the other way round. For Apeos Manager this resolves to
    /// the literal it has always used, leaving passwords from earlier builds readable.
    private static let service = Bundle.main.bundleIdentifier ?? "nz.co.myers.ApeosManager"

    static func set(_ password: String, account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(password.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        SecItemAdd(add as CFDictionary, nil)
    }

    /// Distinguishes "no password saved" from "saved but this build cannot read it".
    /// The latter happens whenever the app's code signature changes, because keychain
    /// access control is bound to the code identity.
    enum Lookup {
        case found(String)
        case notFound
        case denied(OSStatus)
    }

    static func lookup(account: String) -> Lookup {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        switch status {
        case errSecSuccess:
            if let data = out as? Data, let s = String(data: data, encoding: .utf8) {
                return .found(s)
            }
            return .notFound
        case errSecItemNotFound:
            return .notFound
        default:
            return .denied(status)
        }
    }

    static func get(account: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func remove(account: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ] as CFDictionary)
    }
}
