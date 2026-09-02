import Foundation

/// One destination on a contact. The device nests the details under a key named after
/// DestType (Email, Smb, Ftp, ...), so the useful target is flattened out here.
struct Destination: Hashable, Sendable, Identifiable {
    let destId: String
    let type: String
    let oneTouchKeyId: Int?
    let target: String

    var id: String { destId.isEmpty ? "\(type)-\(target)" : destId }

    var label: String {
        type.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

struct Contact: Identifiable, Hashable, Sendable {
    let contactId: String
    let contactType: String     // PERSON / GROUP
    let favorite: Bool
    let displayName: String
    let lastName: String
    let firstName: String
    let company: String
    let key: String
    let destinations: [Destination]

    var id: String { contactId }

    /// `favorite` is a `let` so a contact cannot drift out of step with the device by
    /// accident; this is the one sanctioned way to move it, after a confirmed write.
    func settingFavorite(_ value: Bool) -> Contact {
        Contact(contactId: contactId, contactType: contactType, favorite: value,
                displayName: displayName, lastName: lastName, firstName: firstName,
                company: company, key: key, destinations: destinations)
    }

    var name: String {
        if !displayName.isEmpty { return displayName }
        let joined = [firstName, lastName].filter { !$0.isEmpty }.joined(separator: " ")
        return joined.isEmpty ? contactId : joined
    }

    /// Stable across printers: the same person is the same contact everywhere, but
    /// ContactId is per-device, so identity is the primary destination when there is one.
    var fleetKey: String {
        if let first = destinations.first(where: { !$0.target.isEmpty }) {
            return first.target.lowercased()
        }
        return name.lowercased()
    }

    var summary: String {
        destinations.map(\.target).filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

struct AddressBookPage: Decodable, Sendable {
    let supported: Bool
    /// Total contacts on the device, used to page through the list.
    let contactCount: Int
    /// Per-channel totals the device reports alongside the count.
    let counts: [String: Int]
    let contacts: [Contact]

    enum CodingKeys: String, CodingKey {
        case supported = "Supported"
        case contactCount = "ContactCount"
        case contacts = "ContactList"
    }

    private struct RawContact: Decodable {
        let contactId: String?
        let contactType: String?
        let favorite: Bool?
        let displayName: String?
        let lastName: String?
        let firstName: String?
        let companyName: String?
        let key: String?
        let destList: [RawDest]?

        enum CodingKeys: String, CodingKey {
            case contactId = "ContactId", contactType = "ContactType", favorite = "Favorite"
            case displayName = "DisplayName", lastName = "LastName", firstName = "FirstName"
            case companyName = "CompanyName", key = "Key", destList = "DestList"
        }
    }

    /// Destination detail lives under a type-named object; capture whichever is present
    /// rather than modelling every channel the fleet might enable.
    private struct RawDest: Decodable {
        let destId: String?
        let destType: String?
        let oneTouchKeyId: Int?
        let detail: [String: [String: String]]

        enum CodingKeys: String, CodingKey {
            case destId = "DestId", destType = "DestType", oneTouchKeyId = "OneTouchKeyId"
        }

        struct Dynamic: CodingKey {
            var stringValue: String; var intValue: Int?
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { return nil }
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            destId = try? c.decode(String.self, forKey: .destId)
            destType = try? c.decode(String.self, forKey: .destType)
            oneTouchKeyId = try? c.decode(Int.self, forKey: .oneTouchKeyId)

            var found: [String: [String: String]] = [:]
            if let dyn = try? decoder.container(keyedBy: Dynamic.self) {
                for key in dyn.allKeys where !["DestId", "DestType", "OneTouchKeyId", "DestFavorite"].contains(key.stringValue) {
                    if let nested = try? dyn.decode([String: String].self, forKey: key) {
                        found[key.stringValue] = nested
                    }
                }
            }
            detail = found
        }

        /// Prefers an address-like field, falling back to the first value present.
        var target: String {
            let preferred = ["MailAddress", "ServerName", "HostName", "Address", "FaxNumber",
                             "SavePath", "SharedName", "LoginName"]
            for (_, fields) in detail {
                for key in preferred {
                    if let v = fields[key], !v.isEmpty { return v }
                }
            }
            for (_, fields) in detail {
                if let v = fields.values.first(where: { !$0.isEmpty }) { return v }
            }
            return ""
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        supported = c.value(.supported, or: true)
        // ContactCount is an OBJECT of per-channel totals with the real total nested
        // inside it under the same name -- not the integer the name suggests.
        if let n = c.decodeLenientInt(.contactCount) {
            contactCount = n
            counts = [:]
        } else if let obj = try? c.decode([String: JSONValue].self, forKey: .contactCount) {
            var ints: [String: Int] = [:]
            for (k, v) in obj { if case .int(let i) = v { ints[k] = i } }
            counts = ints
            contactCount = ints["ContactCount"] ?? ints["PersonContactCount"] ?? 0
        } else {
            contactCount = 0
            counts = [:]
        }
        let raw = c.value(.contacts, or: [RawContact]())
        contacts = raw.map { r in
            Contact(contactId: r.contactId ?? "",
                    contactType: r.contactType ?? "PERSON",
                    favorite: r.favorite ?? false,
                    displayName: r.displayName ?? "",
                    lastName: r.lastName ?? "",
                    firstName: r.firstName ?? "",
                    company: r.companyName ?? "",
                    key: r.key ?? "",
                    destinations: (r.destList ?? []).map {
                        Destination(destId: $0.destId ?? "",
                                    type: $0.destType ?? "UNKNOWN",
                                    oneTouchKeyId: $0.oneTouchKeyId,
                                    target: $0.target)
                    })
        }
    }
}


/// Minimal JSON value used where the device returns mixed-type objects.
enum JSONValue: Decodable {
    case int(Int), bool(Bool), string(String), other

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int.self) { self = .int(i) }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else { self = .other }
    }
}
