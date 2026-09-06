import Foundation

// MARK: - /home/api/about

struct DeviceAbout: Codable, Sendable {
    var devFrndlName: String = ""
    var hostName: String = ""
    var location: String = ""
    var serialNumber: String = ""
    var softwareVersion: String = ""
    var localEmail: String = ""
    var adminName: String = ""
    var adminEmail: String = ""
    var adminPhone: String = ""
    var adminLocation: String = ""
    var comment: String = ""
    var deviceStatus: String = ""
    var ipv4PrimaryAddress: String = ""

    enum CodingKeys: String, CodingKey {
        case devFrndlName = "DevFrndlName"
        case hostName = "HostName"
        case location = "Location"
        case serialNumber = "SerialNumber"
        case softwareVersion = "SoftwareVersion"
        case localEmail = "LocalEmail"
        case adminName = "AdminName"
        case adminEmail = "AdminEmail"
        case adminPhone = "AdminPhone"
        case adminLocation = "AdminLocation"
        case comment = "Comment"
        case deviceStatus = "DeviceStatus"
        case ipv4PrimaryAddress = "IPv4PrimaryAddress"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        devFrndlName       = c.value(.devFrndlName, or: "")
        hostName           = c.value(.hostName, or: "")
        location           = c.value(.location, or: "")
        serialNumber       = c.value(.serialNumber, or: "")
        softwareVersion    = c.value(.softwareVersion, or: "")
        localEmail         = c.value(.localEmail, or: "")
        adminName          = c.value(.adminName, or: "")
        adminEmail         = c.value(.adminEmail, or: "")
        adminPhone         = c.value(.adminPhone, or: "")
        adminLocation      = c.value(.adminLocation, or: "")
        comment            = c.value(.comment, or: "")
        deviceStatus       = c.value(.deviceStatus, or: "")
        ipv4PrimaryAddress = c.value(.ipv4PrimaryAddress, or: "")
    }
}

// MARK: - /home/api/device-status

struct DeviceStatus: Codable, Sendable {
    let status: String
    enum CodingKeys: String, CodingKey { case status = "Status" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = c.value(.status, or: "UNKNOWN")
    }
}

// MARK: - /home/api/supplies-info

/// The device reports `Remaining` and `PageRemaining` as *strings*, so both are
/// decoded leniently — some models/firmware emit numbers instead.
struct Supply: Codable, Sendable, Identifiable {
    let name: String
    let state: String
    let lifeState: String
    let remaining: Int?
    let pageRemaining: Int?
    let dateInstalled: Date?
    let reorderInfo: String?
    let changeableType: String?

    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name = "Name", state = "State", lifeState = "LifeState"
        case remaining = "Remaining", pageRemaining = "PageRemaining"
        case dateInstalled = "DateInstalled", reorderInfo = "ReorderInfo"
        case changeableType = "ChangeableType"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        state = (try? c.decode(String.self, forKey: .state)) ?? "UNKNOWN"
        lifeState = (try? c.decode(String.self, forKey: .lifeState)) ?? "UNKNOWN"
        remaining = c.decodeLenientInt(.remaining)
        pageRemaining = c.decodeLenientInt(.pageRemaining)
        reorderInfo = try? c.decode(String.self, forKey: .reorderInfo)
        changeableType = try? c.decode(String.self, forKey: .changeableType)
        if let s = try? c.decode(String.self, forKey: .dateInstalled), !s.isEmpty {
            dateInstalled = ISO8601DateFormatter().date(from: s)
        } else {
            dateInstalled = nil
        }
    }

    /// Split "TONER_Y" into a family and a colour so the UI can group and tint.
    var family: String { name.split(separator: "_").first.map(String.init) ?? name }
    var colourCode: String? {
        let parts = name.split(separator: "_")
        return parts.count > 1 ? String(parts[1]) : nil
    }

    var needsAttention: Bool {
        lifeState == "EXCHANGE_TIME" || lifeState == "NEAR_END" || (remaining ?? 100) <= 15
    }
    var isSpent: Bool { lifeState == "EXCHANGE_TIME" || (remaining ?? 100) <= 0 }
}

struct SuppliesInfo: Codable, Sendable {
    let supplies: [Supply]
    enum CodingKeys: String, CodingKey { case supplies = "Supplies" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        supplies = c.value(.supplies, or: [])
    }
}

// MARK: - /home/api/billing-counter

struct UsageCounter: Codable, Sendable, Identifiable {
    let domesticName: String
    let count: Int
    var id: String { domesticName }
    enum CodingKeys: String, CodingKey { case domesticName = "DomesticName", count = "Count" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        domesticName = c.value(.domesticName, or: "UNKNOWN")
        count = c.decodeLenientInt(.count) ?? 0
    }

    /// "PRINT_TOTAL_COLOR_IMPRESSION" -> "Print Total Color Impression"
    var label: String {
        domesticName.split(separator: "_")
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .joined(separator: " ")
    }
    var group: String { domesticName.split(separator: "_").first.map(String.init) ?? "OTHER" }
}

struct BillingCounter: Codable, Sendable {
    let meterSupported: Bool
    let usageCounterSupported: Bool
    let usageCounters: [UsageCounter]
    enum CodingKeys: String, CodingKey {
        case meterSupported = "MeterSupported"
        case usageCounterSupported = "UsageCounterSupported"
        case usageCounters = "UsageCounters"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        meterSupported        = c.value(.meterSupported, or: false)
        usageCounterSupported = c.value(.usageCounterSupported, or: true)
        usageCounters         = c.value(.usageCounters, or: [])
    }
}

// MARK: - /home/api/paper-tray

// Read-only: the app never writes a tray back, and the decoder reads keys the
// firmware spells more than one way, which a synthesised encoder cannot mirror.
struct PaperTray: Decodable, Sendable, Identifiable {
    let nameId: String
    /// Unique only within a tray type: the bypass is "1_SMH" while the first cassette
    /// is "1_TRAY", so both report LogicalNum 1. Identifying a tray by it alone gives
    /// SwiftUI two rows with one id, which is undefined behaviour and did crash the
    /// Trays table. PhysicalNum is the per-device number, and the number the printer's
    /// own web UI prints on each tray.
    let logicalNum: Int
    let physicalNum: Int?
    let logicalTrayType: String?
    let mediumSize: String?
    let mediumType: String?
    let mediumColor: String?
    let mediumSizeSupported: [String]?
    let mediumTypeSupported: [String]?
    let status: String?
    /// Paper left, as a percentage. Nil where the device cannot measure this tray: the
    /// firmware answers with a negative sentinel (-2, -3) rather than omitting the key,
    /// and a bypass tray reports one even on a model that measures its cassettes.
    let remaining: Int?

    var id: String { "\(physicalNum ?? logicalNum)_\(nameId)" }

    enum CodingKeys: String, CodingKey {
        case nameId = "NameId", logicalNum = "LogicalNum", physicalNum = "PhysicalNum"
        case logicalTrayType = "LogicalTrayType"
        case mediumSize = "MediumSize", mediumType = "MediumType"
        case color = "Color", mediumColor = "MediumColor"
        case mediumSizeSupported = "MediumSizeSupported"
        case mediumTypeSupported = "MediumTypeSupported"
        case status = "Status", remaining = "Remaining", volume = "Volume"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nameId               = c.value(.nameId, or: "TRAY")
        logicalNum           = c.decodeLenientInt(.logicalNum) ?? 0
        physicalNum          = c.decodeLenientInt(.physicalNum)
        logicalTrayType      = c.value(.logicalTrayType, or: nil)
        mediumSize           = c.value(.mediumSize, or: nil)
        mediumType           = c.value(.mediumType, or: nil)
        // The paper's own colour is "Color" on these devices; "MediumColor" is read as
        // well because the size and type keys either side of it are both prefixed.
        mediumColor          = c.value(.color, or: nil) ?? c.value(.mediumColor, or: nil)
        mediumSizeSupported  = c.value(.mediumSizeSupported, or: nil)
        mediumTypeSupported  = c.value(.mediumTypeSupported, or: nil)
        status               = c.value(.status, or: nil)
        let level            = c.decodeLenientInt(.remaining) ?? c.decodeLenientInt(.volume)
        remaining            = level.flatMap { $0 < 0 ? nil : min($0, 100) }
    }
}

struct PaperTrayInfo: Decodable, Sendable {
    let volumeDetection: Bool?
    let paperTrays: [PaperTray]
    enum CodingKeys: String, CodingKey {
        case volumeDetection = "VolumeDetection", paperTrays = "PaperTrays"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        volumeDetection = c.value(.volumeDetection, or: nil)
        paperTrays      = c.value(.paperTrays, or: [])
    }
}

// MARK: - Lenient decoding helper

extension KeyedDecodingContainer {
    /// Apeos firmware is inconsistent about whether numerics are quoted.
    func decodeLenientInt(_ key: Key) -> Int? {
        if let i = try? decode(Int.self, forKey: key) { return i }
        if let s = try? decode(String.self, forKey: key) { return Int(s) }
        return nil
    }

    /// Field presence varies by model and firmware across a mixed fleet, and Swift's
    /// synthesized Decodable ignores property defaults -- it throws keyNotFound for any
    /// missing non-optional key. Every field is therefore read through a fallback so one
    /// absent key cannot discard an otherwise valid response.
    func value<T: Decodable>(_ key: Key, or fallback: T) -> T {
        (try? decode(T.self, forKey: key)) ?? fallback
    }
}

// MARK: - /home/api/faulthistory

/// One entry from the device's fault log. ChainCode/LinkCode are the two halves of the
/// Fujifilm fault code shown on the panel, e.g. 5 + 144 -> "005-144".
struct FaultEntry: Codable, Sendable, Identifiable, Hashable {
    let chainCode: Int
    let linkCode: Int
    let year: Int
    let month: Int
    let day: Int
    let hour: Int
    let minute: Int
    /// Total impressions at the time of the fault.
    let volume: Int?

    var id: String { "\(code)-\(year)\(month)\(day)\(hour)\(minute)-\(volume ?? 0)" }
    var code: String { String(format: "%03d-%03d", chainCode, linkCode) }

    var date: Date? {
        DateComponents(calendar: .current, year: year, month: month, day: day,
                       hour: hour, minute: minute).date
    }

    enum CodingKeys: String, CodingKey {
        case chainCode = "ChainCode", linkCode = "LinkCode"
        case year = "Year", month = "Month", day = "Day"
        case hour = "Hour", minute = "Minute", volume = "Volume"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        chainCode = c.decodeLenientInt(.chainCode) ?? 0
        linkCode  = c.decodeLenientInt(.linkCode) ?? 0
        year      = c.decodeLenientInt(.year) ?? 0
        month     = c.decodeLenientInt(.month) ?? 1
        day       = c.decodeLenientInt(.day) ?? 1
        hour      = c.decodeLenientInt(.hour) ?? 0
        minute    = c.decodeLenientInt(.minute) ?? 0
        volume    = c.decodeLenientInt(.volume)
    }
}

struct FaultHistory: Codable, Sendable {
    let faultHistory: [FaultEntry]
    enum CodingKeys: String, CodingKey { case faultHistory = "FaultHistory" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        faultHistory = c.value(.faultHistory, or: [])
    }
}
