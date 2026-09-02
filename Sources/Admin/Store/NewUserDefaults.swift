import Foundation

/// What a newly added user should start with, remembered on this Mac.
///
/// App-side only: the device has its own notion of a default for a new account, and
/// this never overwrites it silently. These values seed the Add User sheet, and only
/// what the sheet then sends is written -- so clearing these restores the previous
/// behaviour of touching nothing the operator did not set.
///
/// Stored as raw values rather than the enums themselves so that a firmware or model
/// that drops a permission the defaults mention degrades to ignoring it, instead of
/// failing to decode the whole record.
struct NewUserDefaults: Codable, Equatable {
    var userType: String?
    /// Meter type to limit, using `UsageMeter.unlimited` for an uncapped meter. Empty
    /// means the Usage tab starts as it always did, with everything unlimited.
    var limits: [String: Int] = [:]
    /// `PermissionService` raw value to `FeaturePermission` raw value.
    var access: [String: String] = [:]
    var login: String?
    var role: String?
    var groupNumber: Int?
    var groupName: String?

    var isEmpty: Bool {
        userType == nil && limits.isEmpty && access.isEmpty
            && login == nil && role == nil && groupNumber == nil
    }

    var group: AuthorizationGroup? {
        groupNumber.map { AuthorizationGroup(number: $0, name: groupName ?? "") }
    }
}

enum NewUserDefaultsStore {
    private static let key = "newUserDefaults.v1"

    static func load() -> NewUserDefaults {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode(NewUserDefaults.self, from: data)
        else { return NewUserDefaults() }
        return decoded
    }

    static func save(_ value: NewUserDefaults) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    static var exists: Bool {
        !load().isEmpty
    }
}
