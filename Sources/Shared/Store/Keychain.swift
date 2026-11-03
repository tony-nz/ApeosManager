import Foundation
import Security

/// Printer administrator passwords live in the login keychain, never in UserDefaults.
enum Keychain {
    /// Namespaced per app, so the user app cannot read the administrator passwords the
    /// fleet manager saves, nor the other way round. For Apeos Manager this resolves to
    /// the literal it has always used, leaving passwords from earlier builds readable.
    private static let service = Bundle.main.bundleIdentifier ?? "nz.co.myers.ApeosManager"

    /// Updates in place, adding only when there is nothing to update. Deleting first
    /// would throw away the item's access list, and with it every "Always Allow" already
    /// granted, and a failed add after a successful delete would lose the password.
    /// Returns whether the password is now stored; a refusal must reach the operator,
    /// who otherwise believes it was remembered.
    @discardableResult
    static func set(_ password: String, account: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let value = Data(password.utf8)
        let updated = SecItemUpdate(base as CFDictionary,
                                    [kSecValueData as String: value] as CFDictionary)
        guard updated == errSecItemNotFound else { return updated == errSecSuccess }
        var add = base
        add[kSecValueData as String] = value
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
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
        if case .found(let password) = lookup(account: account) { return password }
        return nil
    }

    static func remove(account: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ] as CFDictionary)
    }
}
