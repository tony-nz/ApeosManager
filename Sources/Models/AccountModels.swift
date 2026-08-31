import Foundation

/// A department / accounting account on the device ("Account" in Fujifilm's model).
struct DeptAccount: Identifiable, Hashable, Sendable {
    var accountID: String
    var name: String
    var newUserDefault: Bool
    /// Usage counters keyed by the child element name the device returns.
    var usage: [String: Int] = [:]

    var id: String { accountID }
    var isEmptySlot: Bool { name.isEmpty }
}

/// A user record. `userType` is KO (key operator / system administrator) or
/// CO (customer operator / ordinary user) -- the values the device's own web UI
/// filters on.
struct DeviceUser: Identifiable, Hashable, Sendable {
    var userID: String
    var userName: String
    var userType: String
    var initials: String = ""
    var roles: [String] = []
    /// Accounting meters, keyed by type. Empty until usage is loaded.
    var usage: [UsageMeter] = []
    /// Account IDs this user is associated with.
    var associates: [String] = []

    var id: String { userID }
    var displayName: String { userName.isEmpty ? userID : userName }
}

/// One accounting meter for a user: how much of a feature they have used, and the cap.
struct UsageMeter: Identifiable, Hashable, Sendable {
    /// CopyColor, CopyBW, PrintColor, PrintBW, ScanColor, ScanBW
    let type: String
    var limit: Int?
    var used: Int
    var remaining: Int?

    var id: String { type }

    /// The device uses 9999999 to mean "no practical limit".
    static let unlimited = 9_999_999
    var isUnlimited: Bool { (limit ?? Self.unlimited) >= Self.unlimited }

    var feature: String {
        if type.hasPrefix("Copy") { return "Copy" }
        if type.hasPrefix("Print") { return "Print" }
        if type.hasPrefix("Scan") { return "Scan" }
        return type
    }
    var isColour: Bool { type.hasSuffix("Color") }
    var label: String { "\(feature) \(isColour ? "Colour" : "Black & White")" }

    var fraction: Double {
        guard let limit, limit > 0, !isUnlimited else { return 0 }
        return min(1, Double(used) / Double(limit))
    }

    static let allTypes = ["CopyColor", "CopyBW", "PrintColor", "PrintBW", "ScanColor", "ScanBW"]
}

enum AaaUserType: String, CaseIterable, Identifiable {
    case keyOperator = "KO"
    case customerOperator = "CO"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .keyOperator:      return "Administrator"
        case .customerOperator: return "User"
        }
    }
}
