import Foundation

/// The fictional fleet a demo run shows.
///
/// Not a random sample: one of everything worth documenting, so that each state in the
/// screenshots and the manual has something to point at. Five printers cover the plain
/// failure (unreachable), the differently-broken one (reachable but refusing reads
/// without an administrator password), the deceptive one (panel says Ready while a drum
/// is spent and the same fault code has fired eleven times), a consumables warning, and
/// enough healthy hardware for the proportions to look like a real site.
///
/// Everything in here is invented. Names are desks and departments rather than people --
/// this fleet's user records are shared position accounts, which is both common on print
/// hardware and the one shape of directory that cannot be mistaken for somebody's real
/// staff list. Addresses are in `10.20.30.0/24` and mail goes to `example.net`.
///
/// Timestamps are computed from `Date()` at call time, never fixed. A fixture with
/// hard-coded dates reads as stale five minutes after it is written, and every window
/// captured from it gets captioned "out of date".
enum DemoFleet {

    // MARK: - The fleet

    /// What each printer is here to demonstrate.
    enum Condition: Sendable {
        /// Nothing wrong. Most of the fleet, or the failures do not read as failures.
        case healthy
        /// Consumables warning: a colour toner and the waste bottle are nearly done.
        case lowToner
        /// Unreachable. The plain broken case.
        case offline
        /// Reads Ready at the top and is not: a spent drum, an empty tray, and one
        /// fault code repeating. The best argument for the app there is.
        case hiddenFault
        /// Answers, but serves nothing without an administrator session. A different
        /// problem from being offline, and the app distinguishes them.
        case needsSignIn
    }

    struct DemoPrinter: Identifiable, Sendable {
        let id: UUID
        let name: String
        let host: String
        let model: String
        let serial: String
        let firmware: String
        let location: String
        let condition: Condition
        /// User IDs with an account on this device. Not every user exists everywhere,
        /// which is the whole reason the fleet views count coverage.
        let holds: Set<String>
        /// Impressions on the clock, which anchors the counters and the fault volumes.
        let impressions: Int

        /// True when the device will not answer a read at all.
        var isReachable: Bool { condition != .offline }
        /// True when reads need an administrator session this demo has no password for.
        var refusesAnonymousReads: Bool { condition == .needsSignIn }
    }

    /// Fixed identifiers, so a printer keeps its place in the sidebar and its window
    /// frames across demo launches. A fresh UUID each run would reshuffle the fleet
    /// between two captures of the same screen.
    static let printers: [DemoPrinter] = [
        DemoPrinter(id: UUID(uuidString: "D3110000-0000-4000-A000-000000000001")!,
                    name: "Reception", host: "10.20.30.11",
                    model: "ApeosPort C5570", serial: "DM3-914207",
                    firmware: "1.12.4", location: "Ground floor, front desk",
                    condition: .healthy, holds: everyone, impressions: 412_806),
        DemoPrinter(id: UUID(uuidString: "D3110000-0000-4000-A000-000000000002")!,
                    name: "Accounts Copy Room", host: "10.20.30.12",
                    model: "ApeosPort C4570", serial: "DM3-914533",
                    firmware: "1.12.4", location: "First floor, room 1.14",
                    condition: .lowToner, holds: headOffice, impressions: 268_140),
        DemoPrinter(id: UUID(uuidString: "D3110000-0000-4000-A000-000000000003")!,
                    name: "Goods In", host: "10.20.30.21",
                    model: "Apeos 4570", serial: "DM4-118862",
                    firmware: "1.9.7", location: "Warehouse, loading bay",
                    condition: .offline, holds: warehouse, impressions: 96_455),
        DemoPrinter(id: UUID(uuidString: "D3110000-0000-4000-A000-000000000004")!,
                    name: "Design Studio", host: "10.20.30.22",
                    model: "ApeosPort C7070", serial: "DM3-902118",
                    firmware: "1.12.1", location: "Second floor, studio",
                    condition: .hiddenFault, holds: studio, impressions: 731_249),
        DemoPrinter(id: UUID(uuidString: "D3110000-0000-4000-A000-000000000005")!,
                    name: "Branch Desk 3", host: "10.20.30.31",
                    model: "ApeosPort C3070", serial: "DM5-330471",
                    firmware: "1.11.9", location: "Branch office, back room",
                    condition: .needsSignIn, holds: branch, impressions: 51_902),
    ]

    static func printer(host: String) -> DemoPrinter? {
        printers.first { $0.host == host }
    }

    /// The administrator account the fleet manager signs in as. Matches the device
    /// default, which is what an operator would actually be typing.
    static let adminUser = "11111"

    /// The account the quota app is signed in as. Capped, and close enough to its cap
    /// for the meter to be worth a screenshot -- an empty allowance shows nothing, and
    /// an exhausted one shows only the end state.
    static let demoUserID = "2041"

    // MARK: - Identity

    static func about(_ p: DemoPrinter) -> DeviceAbout {
        var a = DeviceAbout()
        a.devFrndlName = p.name
        a.hostName = "APEOS-" + p.name.uppercased()
            .replacingOccurrences(of: " ", with: "-")
        a.location = p.location
        a.serialNumber = p.serial
        a.softwareVersion = p.firmware
        a.localEmail = "\(slug(p.name))@example.net"
        a.adminName = "Facilities"
        a.adminEmail = "facilities@example.net"
        a.adminPhone = "555 0143"
        a.adminLocation = "Ground floor, facilities office"
        a.comment = p.model
        a.deviceStatus = p.condition == .hiddenFault ? "READY" : "READY"
        a.ipv4PrimaryAddress = p.host
        return a
    }

    static func status(_ p: DemoPrinter) -> DeviceStatus? {
        // Deliberately READY on the printer with the spent drum. A device that reports
        // its own trouble needs no fleet manager to find it; the one that does not is
        // the reason this app exists.
        decode(DeviceStatus.self, ["Status": p.condition == .lowToner ? "WARNING" : "READY"])
    }

    // MARK: - Consumables

    static func supplies(_ p: DemoPrinter, now: Date = Date()) -> [Supply] {
        let installed = { (days: Int) in
            iso(now.addingTimeInterval(-Double(days) * 86_400))
        }
        switch p.condition {
        case .healthy, .needsSignIn:
            return supplies([
                ("TONER_K", "READY", "READY", 74, 9_600, installed(96)),
                ("TONER_C", "READY", "READY", 61, 7_300, installed(96)),
                ("TONER_M", "READY", "READY", 58, 6_900, installed(96)),
                ("TONER_Y", "READY", "READY", 66, 7_900, installed(96)),
                ("DRUM_K",  "READY", "READY", 82, nil,   installed(210)),
                ("DRUM_C",  "READY", "READY", 79, nil,   installed(210)),
                ("DRUM_M",  "READY", "READY", 80, nil,   installed(210)),
                ("DRUM_Y",  "READY", "READY", 81, nil,   installed(210)),
                ("WASTE_TONER", "READY", "READY", 55, nil, installed(210)),
            ])
        case .lowToner:
            // The ordinary consumable warning: the device says so itself, and the app's
            // job is only to say it somewhere an operator will see it.
            return supplies([
                ("TONER_K", "READY", "READY", 44, 5_700, installed(74)),
                ("TONER_C", "WARNING", "NEAR_END", 8, 900, installed(74)),
                ("TONER_M", "READY", "READY", 51, 6_100, installed(74)),
                ("TONER_Y", "WARNING", "NEAR_END", 12, 1_400, installed(74)),
                ("DRUM_K",  "READY", "READY", 63, nil, installed(180)),
                ("DRUM_C",  "READY", "READY", 60, nil, installed(180)),
                ("DRUM_M",  "READY", "READY", 62, nil, installed(180)),
                ("DRUM_Y",  "READY", "READY", 61, nil, installed(180)),
                ("WASTE_TONER", "WARNING", "NEAR_END", 9, nil, installed(180)),
            ])
        case .hiddenFault:
            // Toner is fine, which is what the panel and the status endpoint report on.
            // The drum underneath is finished and the fuser is close behind.
            return supplies([
                ("TONER_K", "READY", "READY", 70, 8_800, installed(41)),
                ("TONER_C", "READY", "READY", 66, 8_100, installed(41)),
                ("TONER_M", "READY", "READY", 72, 8_900, installed(41)),
                ("TONER_Y", "READY", "READY", 69, 8_400, installed(41)),
                ("DRUM_K",  "READY", "READY", 48, nil, installed(240)),
                ("DRUM_C",  "ERROR", "EXCHANGE_TIME", 0, nil, installed(392)),
                ("DRUM_M",  "READY", "READY", 44, nil, installed(240)),
                ("DRUM_Y",  "READY", "READY", 46, nil, installed(240)),
                ("FUSER",   "WARNING", "NEAR_END", 4, nil, installed(392)),
                ("WASTE_TONER", "READY", "READY", 38, nil, installed(240)),
            ])
        case .offline:
            return []
        }
    }

    // MARK: - Counters

    static func counters(_ p: DemoPrinter) -> [UsageCounter] {
        guard p.isReachable else { return [] }
        let total = p.impressions
        let colour = Int(Double(total) * 0.31)
        let mono = total - colour
        return counters([
            ("TOTAL_IMPRESSIONS", total),
            ("TOTAL_COLOR", colour),
            ("TOTAL_BLACK", mono),
            ("COPY_COLOR", Int(Double(colour) * 0.24)),
            ("COPY_BLACK", Int(Double(mono) * 0.19)),
            ("PRINT_COLOR", Int(Double(colour) * 0.76)),
            ("PRINT_BLACK", Int(Double(mono) * 0.81)),
            ("SCAN_TOTAL", Int(Double(total) * 0.14)),
            ("FAX_SENT", p.condition == .healthy ? 1_284 : 0),
        ])
    }

    // MARK: - Paper

    static func trays(_ p: DemoPrinter) -> [PaperTray] {
        guard p.isReachable else { return [] }
        // The empty tray on the studio machine is part of the same picture as the drum:
        // nothing at the top of the screen mentions either.
        let three: (String, Int) = p.condition == .hiddenFault ? ("EMPTY", 0) : ("READY", 100)
        return trays([
            (1, "TRAY_1", "A4",  "PLAIN",      "WHITE",  "READY", 100),
            (2, "TRAY_2", "A4",  "PLAIN",      "WHITE",  "READY", 75),
            (3, "TRAY_3", "A3",  "PLAIN",      "WHITE",  three.0, three.1),
            (4, "TRAY_4", "A4",  "RECYCLED",   "WHITE",  "NEAR_EMPTY", 25),
            (5, "BYPASS", "A4",  "HEAVYWEIGHT", "CREAM", "READY", 50),
        ])
    }

    // MARK: - Faults

    static func faults(_ p: DemoPrinter, now: Date = Date()) -> [FaultEntry] {
        switch p.condition {
        case .offline:
            return []
        case .hiddenFault:
            // One code, over and over, on a device whose status endpoint says READY.
            // A fleet-wide log is the only place this pattern is visible at all.
            var out: [FaultEntry] = []
            for (index, hoursAgo) in [6, 19, 31, 52, 77, 96, 121, 168, 214, 266, 310].enumerated() {
                out.append(contentsOf: fault("010-320", hoursAgo, p.impressions - index * 340, now))
            }
            out.append(contentsOf: fault("093-970", 402, p.impressions - 5_100, now))
            out.append(contentsOf: fault("024-747", 690, p.impressions - 9_800, now))
            return out
        case .lowToner:
            return fault("093-912", 58, p.impressions - 400, now)
                 + fault("010-311", 340, p.impressions - 3_200, now)
        case .healthy, .needsSignIn:
            return fault("024-747", 512, p.impressions - 4_400, now)
                 + fault("093-912", 1_180, p.impressions - 14_900, now)
        }
    }

    // MARK: - Jobs

    /// Job history for one printer, newest first. Deterministic per printer, so two
    /// captures of the same screen agree, but dated from the moment it is asked for.
    static func jobs(_ p: DemoPrinter, max: Int = 100, now: Date = Date()) -> [JobRecord] {
        guard p.isReachable else { return [] }
        let members = users.filter { p.holds.contains($0.userID) }
        guard !members.isEmpty else { return [] }

        var out: [JobRecord] = []
        var seed = stableHash(p.host) | 1
        func next(_ bound: Int) -> Int {
            // A small deterministic generator, so the same fixture reads the same way
            // in every capture without hard-coding two hundred rows by hand.
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int(seed >> 33) % bound
        }

        var minutesAgo = 4
        for index in 0..<min(max, 84) {
            let user = members[next(members.count)]
            let isPrint = next(10) < 6
            let isColour = next(10) < 4
            let sheets = 1 + next(24)
            let copies = isPrint ? 1 : 1 + next(3)
            let created = now.addingTimeInterval(-Double(minutesAgo) * 60)
            minutesAgo += 7 + next(190)
            out.append(JobRecord(
                jobID: 20_400 - index,
                type: isPrint ? "PRINT" : (next(4) == 0 ? "SCAN" : "COPY"),
                userName: user.userName,
                userID: user.userID,
                state: next(40) == 0 ? "CANCELLED" : "COMPLETED",
                created: created,
                completed: created.addingTimeInterval(Double(12 + sheets * 3)),
                colour: isColour ? "FULL_COLOR" : "MONOCHROME",
                mediumSize: next(8) == 0 ? "A3" : "A4",
                sheets: sheets,
                impressions: sheets * copies,
                copies: copies,
                protocolName: isPrint ? "IPP" : "",
                fileName: isPrint ? jobFiles[next(jobFiles.count)] : "",
                fileNameHidden: false))
        }
        return out
    }

    private static let jobFiles = [
        "Delivery note 4471.pdf", "Weekly roster.xlsx", "Signage proof v3.pdf",
        "Purchase order 20834.pdf", "Induction pack.pdf", "Shelf labels.pdf",
        "Meeting agenda.docx", "Invoice batch.pdf", "Floor plan A3.pdf",
        "Safety notice.pdf", "Price list Q3.pdf", "Packing slip.pdf",
    ]

    // MARK: - Address book

    static func contacts(_ p: DemoPrinter) -> [Contact] {
        guard p.isReachable else { return [] }
        // The branch machine keeps a shorter book, so the fleet view has something to
        // report as missing rather than every device agreeing.
        let entries = p.condition == .hiddenFault ? addressBook : Array(addressBook.prefix(9))
        return entries.enumerated().map { index, entry in
            Contact(contactId: String(index + 1),
                    contactType: "PERSON",
                    favorite: entry.favourite,
                    displayName: entry.name,
                    lastName: "", firstName: "",
                    company: entry.company,
                    key: entry.name,
                    destinations: [Destination(destId: "\(index + 1)-1",
                                               type: "MAIL",
                                               oneTouchKeyId: index < 6 ? index + 1 : nil,
                                               target: entry.email)])
        }
    }

    private struct BookEntry { let name, company, email: String; let favourite: Bool }
    private static let addressBook: [BookEntry] = [
        BookEntry(name: "Accounts Inbox", company: "Head Office", email: "accounts@example.net", favourite: true),
        BookEntry(name: "Branch Office", company: "Branch", email: "branch@example.net", favourite: true),
        BookEntry(name: "Design Studio", company: "Head Office", email: "studio@example.net", favourite: true),
        BookEntry(name: "Dispatch", company: "Warehouse", email: "dispatch@example.net", favourite: false),
        BookEntry(name: "Facilities", company: "Head Office", email: "facilities@example.net", favourite: true),
        BookEntry(name: "Goods In", company: "Warehouse", email: "goodsin@example.net", favourite: false),
        BookEntry(name: "Health & Safety", company: "Head Office", email: "safety@example.net", favourite: false),
        BookEntry(name: "Marketing", company: "Head Office", email: "marketing@example.net", favourite: false),
        BookEntry(name: "Payroll", company: "Head Office", email: "payroll@example.net", favourite: true),
        BookEntry(name: "Purchasing", company: "Head Office", email: "purchasing@example.net", favourite: false),
        BookEntry(name: "Quality Office", company: "Workshop", email: "quality@example.net", favourite: false),
        BookEntry(name: "Reception", company: "Head Office", email: "reception@example.net", favourite: true),
        BookEntry(name: "Training Room", company: "Head Office", email: "training@example.net", favourite: false),
        BookEntry(name: "Workshop Office", company: "Workshop", email: "workshop@example.net", favourite: false),
    ]

    // MARK: - Users

    /// Who has an account where.
    ///
    /// Coverage has to vary between the printers that *can* be read, not only between
    /// those and the two that cannot. A fleet where every account is on every readable
    /// device gives the Users screen's "missing from some printers" filter nothing to
    /// find, which is the one question that screen exists to answer.
    private static let everyone: Set<String> = Set(userTemplates.map(\.id))
    /// The warehouse desks have no reason to hold an account in the accounts copy room.
    private static let headOffice: Set<String> = everyone.subtracting(["2044", "2048", "2049"])
    /// Nor do they, or the branch, in the studio -- and the disused spare was never
    /// created there at all.
    private static let studio: Set<String> =
        everyone.subtracting(["2044", "2045", "2046", "2048", "2049", "2058"])
    private static let warehouse: Set<String> = ["11111", "2044", "2048", "2049", "2052"]
    private static let branch: Set<String> = ["11111", "2045", "2046", "2050", "2051"]

    private struct UserTemplate {
        let id: String
        let name: String
        let type: String
        /// Per-printer caps, by meter type. An absent type means uncapped there.
        let limits: [String: Int]
        /// Roughly how hard this account is used, 0...1, against its own caps.
        let load: Double
        let accounts: [String]
    }

    /// The directory. Position accounts rather than people, sized so the fleet views
    /// have to page and the proportions look like a site rather than a test.
    private static let userTemplates: [UserTemplate] = [
        UserTemplate(id: "11111", name: "System Administrator", type: "KO",
                     limits: [:], load: 0.01, accounts: []),
        // Near the cap: the one worth a warning without being over it yet.
        UserTemplate(id: "2041", name: "Reception Desk", type: "CO",
                     limits: ["PrintBW": 1_000, "PrintColor": 250, "CopyBW": 1_500, "CopyColor": 200],
                     load: 0.90, accounts: ["01"]),
        // Over it. Devices let the job that crosses the line finish, so used can exceed
        // the limit by a little -- which is exactly what an operator rings up about.
        UserTemplate(id: "2042", name: "Accounts Payable", type: "CO",
                     limits: ["PrintBW": 1_000, "PrintColor": 250, "CopyBW": 1_500, "CopyColor": 200],
                     load: 1.12, accounts: ["01"]),
        // Uncapped for colour: the studio has to print colour to do its job, and an
        // uncapped meter anywhere uncaps the type fleet-wide.
        UserTemplate(id: "2043", name: "Design Studio 1", type: "CO",
                     limits: ["PrintBW": 2_000, "CopyBW": 2_000], load: 0.61, accounts: ["02"]),
        UserTemplate(id: "2044", name: "Goods In Terminal", type: "CO",
                     limits: ["PrintBW": 800, "PrintColor": 100, "CopyBW": 800, "CopyColor": 100],
                     load: 0.22, accounts: ["03"]),
        UserTemplate(id: "2045", name: "Branch Desk 3", type: "CO",
                     limits: ["PrintBW": 600, "PrintColor": 150, "CopyBW": 600, "CopyColor": 150],
                     load: 0.44, accounts: ["04"]),
        UserTemplate(id: "2046", name: "Branch Desk 1", type: "CO",
                     limits: ["PrintBW": 600, "PrintColor": 150, "CopyBW": 600, "CopyColor": 150],
                     load: 0.37, accounts: ["04"]),
        UserTemplate(id: "2047", name: "Payroll Office", type: "CO",
                     limits: ["PrintBW": 1_200, "PrintColor": 200, "CopyBW": 1_200, "CopyColor": 200],
                     load: 0.58, accounts: ["01"]),
        UserTemplate(id: "2048", name: "Dispatch Desk", type: "CO",
                     limits: ["PrintBW": 800, "PrintColor": 100, "CopyBW": 800, "CopyColor": 100],
                     load: 0.51, accounts: ["03"]),
        UserTemplate(id: "2049", name: "Workshop Office", type: "CO",
                     limits: ["PrintBW": 800, "PrintColor": 100, "CopyBW": 800, "CopyColor": 100],
                     load: 0.29, accounts: ["03"]),
        UserTemplate(id: "2050", name: "Meeting Room A", type: "CO",
                     limits: ["PrintBW": 500, "PrintColor": 100, "CopyBW": 500, "CopyColor": 100],
                     load: 0.12, accounts: ["05"]),
        UserTemplate(id: "2051", name: "Training Room", type: "CO",
                     limits: ["PrintBW": 1_500, "PrintColor": 300, "CopyBW": 1_500, "CopyColor": 300],
                     load: 0.66, accounts: ["05"]),
        UserTemplate(id: "2052", name: "Quality Office", type: "CO",
                     limits: ["PrintBW": 800, "PrintColor": 150, "CopyBW": 800, "CopyColor": 150],
                     load: 0.48, accounts: ["06"]),
        UserTemplate(id: "2053", name: "Marketing Desk", type: "CO",
                     limits: ["PrintBW": 700, "PrintColor": 400, "CopyBW": 700, "CopyColor": 400],
                     load: 0.72, accounts: ["02"]),
        UserTemplate(id: "2054", name: "Purchasing Desk", type: "CO",
                     limits: ["PrintBW": 900, "PrintColor": 150, "CopyBW": 900, "CopyColor": 150],
                     load: 0.55, accounts: ["01"]),
        UserTemplate(id: "2055", name: "Facilities Office", type: "CO",
                     limits: ["PrintBW": 700, "PrintColor": 150, "CopyBW": 700, "CopyColor": 150],
                     load: 0.34, accounts: ["06"]),
        UserTemplate(id: "2056", name: "Print Room Operator", type: "CO",
                     limits: ["PrintBW": 3_000, "PrintColor": 800, "CopyBW": 3_000, "CopyColor": 800],
                     load: 0.79, accounts: ["02"]),
        UserTemplate(id: "2057", name: "Health & Safety", type: "CO",
                     limits: ["PrintBW": 600, "PrintColor": 100, "CopyBW": 600, "CopyColor": 100],
                     load: 0.19, accounts: ["06"]),
        // Left on the device but no longer in use -- the record an audit is looking for.
        UserTemplate(id: "2058", name: "Old Reception (spare)", type: "CO",
                     limits: ["PrintBW": 500, "PrintColor": 100, "CopyBW": 500, "CopyColor": 100],
                     load: 0.0, accounts: []),
    ]

    /// The directory without per-printer meters -- the shape the fleet-wide user list
    /// wants, where only membership and identity matter.
    static let users: [DeviceUser] = userTemplates.map {
        DeviceUser(userID: $0.id, userName: $0.name, userType: $0.type,
                   initials: initials($0.name),
                   roles: $0.type == "KO" ? ["SA"] : ["CO"],
                   usage: [], associates: $0.accounts)
    }

    /// The directory as one printer holds it, meters included.
    static func users(_ p: DemoPrinter) -> [DeviceUser] {
        userTemplates.filter { p.holds.contains($0.id) }.map { template in
            DeviceUser(userID: template.id, userName: template.name,
                       userType: template.type, initials: initials(template.name),
                       roles: template.type == "KO" ? ["SA"] : ["CO"],
                       usage: meters(template, on: p),
                       associates: template.accounts)
        }
    }

    /// This user's meters on this printer.
    ///
    /// Caps are the same everywhere -- an administrator sets one policy and applies it
    /// to the fleet -- while usage differs per device, which is what makes the fleet
    /// totals worth assembling in the first place.
    static func meters(userID: String, on p: DemoPrinter) -> [UsageMeter] {
        guard let template = userTemplates.first(where: { $0.id == userID }) else { return [] }
        return meters(template, on: p)
    }

    private static func meters(_ t: UserTemplate, on p: DemoPrinter) -> [UsageMeter] {
        // A fixed per-printer skew, so one device is not a copy of the next, without
        // the numbers moving between two captures of the same window. Kept narrow: it
        // is here to stop the fleet looking generated, not to decide who is over their
        // limit -- that is the template's `load`, and it must hold on every printer.
        let skew = 0.92 + Double(stableHash(p.host) % 17) / 100.0
        return UsageMeter.allTypes.map { type in
            guard let limit = t.limits[type] else {
                // No cap set for this feature. The device does not omit the meter, it
                // reports its 9999999 sentinel, and the app has to read that back as
                // "unlimited" rather than as an enormous but finite allowance.
                return UsageMeter(type: type, limit: UsageMeter.unlimited,
                                  used: Int(320 * t.load * skew), remaining: nil)
            }
            let used = Int(Double(limit) * t.load * skew)
            return UsageMeter(type: type, limit: limit, used: used,
                              remaining: max(0, limit - used))
        }
    }

    // MARK: - Accounts and permissions

    static func accounts(_ p: DemoPrinter) -> [DeptAccount] {
        guard p.isReachable else { return [] }
        return [
            DeptAccount(accountID: "01", name: "Head Office", newUserDefault: true,
                        usage: ["ColorCopyTotal": 4_120, "BlackCopyTotal": 18_440]),
            DeptAccount(accountID: "02", name: "Creative", newUserDefault: false,
                        usage: ["ColorCopyTotal": 21_905, "BlackCopyTotal": 6_270]),
            DeptAccount(accountID: "03", name: "Warehouse", newUserDefault: false,
                        usage: ["ColorCopyTotal": 640, "BlackCopyTotal": 12_880]),
            DeptAccount(accountID: "04", name: "Branch", newUserDefault: false,
                        usage: ["ColorCopyTotal": 1_755, "BlackCopyTotal": 5_190]),
            DeptAccount(accountID: "05", name: "Meeting Rooms", newUserDefault: false,
                        usage: ["ColorCopyTotal": 980, "BlackCopyTotal": 3_410]),
            DeptAccount(accountID: "06", name: "Support Services", newUserDefault: false,
                        usage: ["ColorCopyTotal": 2_240, "BlackCopyTotal": 9_005]),
        ]
    }

    static let authorizationGroups: [AuthorizationGroup] = [
        AuthorizationGroup(number: 0, name: "DefaultGroup"),
        AuthorizationGroup(number: 1, name: "Colour Allowed"),
        AuthorizationGroup(number: 2, name: "Mono Only"),
        AuthorizationGroup(number: 3, name: "Studio"),
    ]

    static func permissions(userID: String) -> UserPermissions {
        var p = UserPermissions()
        let template = userTemplates.first { $0.id == userID }
        let colourCapped = template.map { $0.limits["PrintColor"] != nil } ?? true
        p.access = [
            .copy: colourCapped ? .limitedColourAndMonochrome : .all,
            .print: colourCapped ? .monochrome : .all,
            .scan: .all,
            .fax: .all,
        ]
        p.login = .manualAndCard
        p.role = template?.type == "KO" ? .systemAdministrator : .localUser
        p.group = colourCapped ? authorizationGroups[2] : authorizationGroups[3]
        p.mailAddress = template.map { "\(slug($0.name))@example.net" }
        p.cardLoginSupported = true
        return p
    }

    /// The raw capability documents the Accounts screen shows verbatim. Written out
    /// rather than assembled, because what that screen is for is showing exactly what
    /// the device returned.
    static func accountingJSON(_ p: DemoPrinter) -> [String: String] {
        guard p.isReachable else {
            return ["Internal Accounting": "— The device did not answer."]
        }
        return [
            "Internal Accounting": """
            {
              "AccountingDeviceType" : "LOCAL",
              "AccountingMode" : "ON",
              "AuthenticationMode" : "LOCAL",
              "MaxUserCount" : 1000,
              "RegisteredUserCount" : \(p.holds.count)
            }
            """,
            "All Users Management": """
            {
              "AllUsersColorCopyLimit" : 9999999,
              "AllUsersColorPrintLimit" : 9999999,
              "ManagementEnabled" : true
            }
            """,
            "Authorization Groups": """
            {
              "Groups" : [
                { "Name" : "DefaultGroup", "Number" : 0 },
                { "Name" : "Colour Allowed", "Number" : 1 },
                { "Name" : "Mono Only", "Number" : 2 },
                { "Name" : "Studio", "Number" : 3 }
              ]
            }
            """,
            "Unit Price": """
            {
              "Currency" : "NZD",
              "ColorPrice" : "0.18",
              "MonochromePrice" : "0.03"
            }
            """,
        ]
    }

    // MARK: - Building the decode-only models

    /// Several of the device models are decode-only: they define `init(from:)`, which
    /// suppresses the synthesised memberwise initialiser, because nothing outside the
    /// client has ever needed to build one by hand. Rather than widen that API for a
    /// fixture, these go through the real `Codable` path -- which has the side benefit
    /// of exercising the decoders the whole app depends on.
    private static func decode<T: Decodable>(_ type: T.Type, _ object: Any) -> T? {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func supplies(
        _ rows: [(String, String, String, Int, Int?, String)]
    ) -> [Supply] {
        rows.compactMap { name, state, life, remaining, pages, installed in
            var o: [String: Any] = ["Name": name, "State": state, "LifeState": life,
                                    "Remaining": String(remaining),
                                    "DateInstalled": installed,
                                    "ChangeableType": "CUSTOMER"]
            if let pages { o["PageRemaining"] = String(pages) }
            return decode(Supply.self, o)
        }
    }

    private static func counters(_ rows: [(String, Int)]) -> [UsageCounter] {
        rows.compactMap { decode(UsageCounter.self, ["DomesticName": $0.0, "Count": $0.1]) }
    }

    private static func trays(
        _ rows: [(Int, String, String, String, String, String, Int)]
    ) -> [PaperTray] {
        rows.compactMap { num, name, size, type, colour, status, volume in
            decode(PaperTray.self, [
                "NameId": name, "LogicalNum": num, "LogicalTrayType": "PAPER_TRAY",
                "MediumSize": size, "MediumType": type, "MediumColor": colour,
                "MediumSizeSupported": ["A3", "A4", "A5", "B4", "B5"],
                "MediumTypeSupported": ["PLAIN", "RECYCLED", "HEAVYWEIGHT", "LABEL"],
                "Status": status, "Volume": volume,
            ])
        }
    }

    /// One fault entry, from a "chain-link" code and how long ago it fired.
    private static func fault(_ code: String, _ hoursAgo: Int,
                              _ volume: Int, _ now: Date) -> [FaultEntry] {
        let halves = code.split(separator: "-").compactMap { Int($0) }
        guard halves.count == 2 else { return [] }
        let when = now.addingTimeInterval(-Double(hoursAgo) * 3_600)
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: when)
        guard let entry = decode(FaultEntry.self, [
            "ChainCode": halves[0], "LinkCode": halves[1],
            "Year": c.year ?? 2026, "Month": c.month ?? 1, "Day": c.day ?? 1,
            "Hour": c.hour ?? 0, "Minute": c.minute ?? 0, "Volume": volume,
        ]) else { return [] }
        return [entry]
    }

    // MARK: - Small helpers

    /// A hash that survives a relaunch.
    ///
    /// `String.hashValue` is seeded per process, so using it here would give the fleet
    /// different numbers on every launch -- and a fixture that will not reproduce is
    /// precisely what a demo mode exists to avoid. FNV-1a, which does not move.
    private static func stableHash(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in s.utf8 { h = (h ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
        return h
    }

    private static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func slug(_ name: String) -> String {
        name.lowercased()
            .replacingOccurrences(of: "&", with: "and")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
    }

    private static func initials(_ name: String) -> String {
        String(name.split(separator: " ").prefix(2).compactMap(\.first)).uppercased()
    }
}
