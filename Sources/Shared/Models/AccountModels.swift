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

// MARK: - User permissions

/// A service whose colour access can be restricted per user, matching the children of
/// `Authorization/ColorModePermission`.
enum PermissionService: String, CaseIterable, Identifiable, Sendable {
    case copy = "Copy"
    case fax = "Fax"
    case scan = "Scan"
    case print = "Print"

    var id: String { rawValue }
    var label: String { "\(rawValue) Feature Access" }
}

/// What a user may do with one service. The raw values are the device's own, and the
/// choices differ per service -- offering a value the service does not accept is
/// rejected as `flt:InvalidArgument`.
enum FeaturePermission: String, CaseIterable, Identifiable, Sendable {
    case all = "All"
    case monochrome = "Monochrome"
    case limitedColourAndMonochrome = "LimitedColorAndMonochrome"
    case colourAndLimitedColourAndMonochrome = "ColorAndLimitedColorAndMonochrome"
    case colour = "Color"
    case none = "None"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all:                                 return "Free Access"
        case .monochrome:                          return "Black & White Only"
        case .limitedColourAndMonochrome:          return "Black & White and Low-Price Colour"
        case .colourAndLimitedColourAndMonochrome: return "Colour, Low-Price Colour and Black & White"
        case .colour:                              return "Colour Only"
        case .none:                                return "No Access"
        }
    }

    /// The values each service accepts, as the device's own editor offers them.
    static func choices(for service: PermissionService) -> [FeaturePermission] {
        switch service {
        case .copy:  return [.all, .monochrome, .limitedColourAndMonochrome, .colour, .none]
        case .fax:   return [.all, .none]
        case .scan:  return [.all, .monochrome, .colour, .none]
        case .print: return [.all, .monochrome, .limitedColourAndMonochrome,
                             .colourAndLimitedColourAndMonochrome, .none]
        }
    }
}

/// Which ways a user may sign in at the panel.
///
/// The device stores this inverted, as `Authentication/ProhibitLoginWith`: a `true`
/// child *prohibits* that method. This enum is the permitted set, which is what the
/// device's own panel shows and what an administrator is actually choosing.
enum LoginPermission: String, CaseIterable, Identifiable, Sendable {
    case manualAndCard = "ManualAndCard"
    case manual = "Manual"
    case card = "Card"
    case none = "None"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .manualAndCard: return "User ID or Card Login"
        case .manual:        return "User ID Login"
        case .card:          return "Card Login"
        case .none:          return "No Login"
        }
    }

    var prohibitsManualEntry: Bool { self == .card || self == .none }
    var prohibitsCardEntry: Bool { self == .manual || self == .none }

    /// `cardEntry` is nil on a device with no card reader, which reports no such child.
    init(prohibitsManualEntry manual: Bool, prohibitsCardEntry card: Bool?) {
        switch (manual, card ?? true) {
        case (true, true):   self = .none
        case (true, false):  self = .card
        case (false, true):  self = .manual
        case (false, false): self = .manualAndCard
        }
    }
}

/// `Authorization/TraditionalRole` -- the user's standing on the device itself.
enum TraditionalRole: String, CaseIterable, Identifiable, Sendable {
    case systemAdministrator = "SA"
    case accountAdministrator = "AA"
    case localUser = "CO"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .systemAdministrator:  return "System Administrator"
        case .accountAdministrator: return "Account Administrator"
        case .localUser:            return "Local User"
        }
    }
}

/// One of the device's numbered permission groups, from
/// `/permissions/api/authorization-groups`.
struct AuthorizationGroup: Identifiable, Hashable, Sendable {
    var number: Int
    var name: String

    var id: Int { number }
    /// "00 DefaultGroup", the form the device's own panel uses.
    var label: String { String(format: "%02d %@", number, name.isEmpty ? "—" : name) }
}

/// The fields behind the device's "User Permissions" and Email "From" Address panels.
///
/// Every field is optional and means "not reported by this device". Models differ over
/// which of these exist -- a device without a fax has no `Fax` permission, one without
/// a card reader has no `CardEntry` -- and writing a field the device does not have is
/// rejected, so only what was read back is ever written.
struct UserPermissions: Hashable, Sendable {
    var access: [PermissionService: FeaturePermission] = [:]
    var login: LoginPermission?
    var role: TraditionalRole?
    var group: AuthorizationGroup?
    var mailAddress: String?
    /// Whether the device reported a `CardEntry` child, i.e. has a card reader.
    var cardLoginSupported = false

    var isEmpty: Bool {
        access.isEmpty && login == nil && role == nil && group == nil && mailAddress == nil
    }
}
