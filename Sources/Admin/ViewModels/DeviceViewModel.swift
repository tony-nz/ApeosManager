import Foundation
import SwiftUI

@MainActor
final class DeviceViewModel: ObservableObject {
    let printer: Printer
    /// Nil only in a demo run, where `ApeosClient.init` refuses to build one.
    private let client: ApeosClient?
    /// The fixture this printer stands for, in a demo run. Nil otherwise.
    private let demo: DemoFleet.DemoPrinter?

    @Published var about: DeviceAbout?
    @Published var status: DeviceStatus?
    @Published var supplies: [Supply] = []
    @Published var counters: [UsageCounter] = []
    @Published var trays: [PaperTray] = []
    @Published var faults: [FaultEntry] = []
    @Published var jobs: [JobRecord] = []
    @Published var contacts: [Contact] = []
    /// How much job history to pull; raised by "Load more".
    @Published var jobLimit = 100

    @Published var isLoading = false
    @Published var isSignedIn = false
    @Published var lastRefresh: Date?
    @Published private(set) var isConnected = false
    @Published var loadingMoreJobs = false
    @Published var errorMessage: String?
    @Published var notice: String?
    /// A password is saved but unreadable by this build (code signature changed).
    var passwordLocked = false

    @Published var accounts: [DeptAccount] = []
    @Published var users: [DeviceUser] = []
    @Published var accountsError: String?
    @Published var usersError: String?
    @Published var accountingUnavailable = false
    @Published var loadingAccounts = false

    /// Capability descriptors from /permissions/api, kept as JSON for reference.
    @Published var accountingJSON: [String: String] = [:]

    /// The stored administrator password, if one was saved when the printer was added.
    private let storedPassword: String?

    /// The in-flight `connect()`, held on the model rather than left to the view that
    /// happened to ask for it. Every screen starts this from `.task`, and SwiftUI
    /// cancels a `.task` when its view goes away -- which used to cancel the sign-in
    /// POST along with it. Because an unstructured Task is not cancelled by the context
    /// awaiting it, navigating away mid-login no longer aborts the login, and callers
    /// arriving while one is running join it instead of starting a second.
    private var connectTask: Task<Void, Never>?
    /// Whether the last sign-in was interrupted rather than refused. A refusal should
    /// not be retried on every view appearance; an interruption must be.
    private var lastSignInCancelled = false

    init(printer: Printer, password: String? = nil) {
        self.printer = printer
        self.storedPassword = password
        self.client = try? ApeosClient(host: printer.host)
        self.demo = DemoMode.isEnabled ? DemoFleet.printer(host: printer.host) : nil
    }

    /// The client, or a refusal.
    ///
    /// Every path that would use it is served from the fixture in a demo run, so
    /// reaching this there is a bug -- and throwing says so, loudly and locally,
    /// instead of silently doing nothing and leaving a blank screen to explain.
    private var api: ApeosClient {
        get throws {
            guard let client else { throw ApeosError.demoMode }
            return client
        }
    }

    /// Signs in (when a password is held) and loads everything. Devices differ over
    /// whether /home/api is readable anonymously, so signing in first is the only
    /// order that works across the fleet.
    func connect() async {
        guard !isConnected else { return }
        let task = connectTask ?? {
            let t = Task { [weak self] in
                guard let self else { return }
                await self.performConnect()
            }
            connectTask = t
            return t
        }()
        await task.value
    }

    private func performConnect() async {
        defer { connectTask = nil }
        guard !isConnected else { return }
        if let demo {
            isConnected = true
            // Signed in wherever an operator would have saved a password. Branch Desk 3
            // is the one with none, which is exactly what makes it the reachable-but-
            // refusing case rather than a second copy of the unreachable one.
            isSignedIn = demo.isReachable && !demo.refusesAnonymousReads
            await refresh()
            await loadDirectory()
            await loadAccounting()
            return
        }
        if let storedPassword, !storedPassword.isEmpty, !isSignedIn {
            await signIn(password: storedPassword)
            // Latched only once the attempt settled. Marking the printer connected
            // before trying -- as this did -- meant one interrupted sign-in left it
            // signed out for the life of the process, because every later view saw
            // `isConnected` and skipped the retry. That is what made a fresh sign-in
            // necessary on almost every launch.
            isConnected = !lastSignInCancelled
        } else {
            if passwordLocked {
                notice = "A saved password exists but this build of the app cannot read it — the app's code signature changed. Sign in once to store it again."
            }
            isConnected = true
            await refresh()
        }
    }

    /// Pulls a deeper slice of job history without re-reading everything else.
    func loadMoreJobs() async {
        jobLimit += 100
        loadingMoreJobs = true
        defer { loadingMoreJobs = false }
        if let demo { jobs = DemoFleet.jobs(demo, max: jobLimit); return }
        do { jobs = try await api.jobHistory(max: jobLimit) }
        catch { errorMessage = error.localizedDescription }
    }

    func reconnect() async {
        connectTask?.cancel()
        connectTask = nil
        isConnected = false
        await connect()
    }

    var suppliesNeedingAttention: [Supply] { supplies.filter(\.needsAttention) }

    /// Endpoint exposure varies by model: some devices serve /home/api reads
    /// anonymously, others require an administrator session for everything except
    /// device-status. Each read is therefore independent -- one 403 must not blank
    /// the whole screen -- and failures are collected rather than thrown away.
    func refresh() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        if let demo {
            await demoRefresh(demo)
            return
        }

        var failures: [String] = []
        var needsAuth = false

        func run(_ label: String, _ work: () async throws -> Void) async {
            do { try await work() }
            catch ApeosError.notAuthenticated {
                needsAuth = true
                failures.append(label)
            }
            catch { failures.append("\(label): \(error.localizedDescription)") }
        }

        await run("device info")  { about    = try await api.about() }
        await run("status")       { status   = try await api.status() }
        await run("supplies")     { supplies = try await api.supplies().supplies }
        await run("counters")     { counters = try await api.counters().usageCounters }
        await run("trays")        { trays    = try await api.trays().paperTrays }
        await run("fault log")    { faults   = try await api.faultHistory().faultHistory }
        await run("job history")  { jobs     = try await api.jobHistory(max: jobLimit) }
        await run("address book") { contacts = try await api.addressBook() }

        lastRefresh = Date()
        if failures.isEmpty {
            errorMessage = nil
        } else if needsAuth && !isSignedIn {
            errorMessage = "This device requires an administrator sign-in to read status. Choose Sign In."
        } else {
            errorMessage = "Could not read: " + failures.joined(separator: ", ")
        }
    }

    func signIn(password: String) async {
        errorMessage = nil
        lastSignInCancelled = false
        if let demo {
            // Any password is accepted: the demo has no credential to check one
            // against, and refusing the operator's guess would only be theatre.
            guard !password.isEmpty else { return }
            isSignedIn = true
            await demoRefresh(demo)
            await loadDirectory()
            await loadAccounting()
            return
        }
        do {
            let result = try await api.login(userID: printer.adminUser, password: password)
            isSignedIn = true
            notice = result.passwordChangeRequired != nil
                ? "The device is requesting an administrator password change."
                : nil
            // Devices that refuse anonymous reads only return data once signed in.
            await refresh()
            await loadAccounting()
            await loadDirectory()
        } catch is CancellationError {
            // The work was called off, not refused. Reporting "cancelled" as a sign-in
            // failure told the user their password was rejected when it was never tried.
            isSignedIn = false
            lastSignInCancelled = true
        } catch let urlError as URLError where urlError.code == .cancelled {
            isSignedIn = false
            lastSignInCancelled = true
        } catch {
            isSignedIn = false
            errorMessage = error.localizedDescription
        }
    }

    func signOut() async {
        if let client { await client.logout() }
        isSignedIn = false
        notice = nil
        accountingJSON = [:]
        accounts = []; users = []
    }

    /// Users and departments come from the SOAP management service, not the JSON API.
    func loadDirectory() async {
        guard isSignedIn else { return }
        loadingAccounts = true
        accountsError = nil; usersError = nil
        defer { loadingAccounts = false }

        if let demo {
            if users.isEmpty { users = DemoFleet.users(demo) }
            if accounts.isEmpty { accounts = DemoFleet.accounts(demo) }
            return
        }

        // Fetched independently: a failure in one must not suppress the other.
        do { users = try await api.getUsers() }
        catch { usersError = error.localizedDescription; users = [] }

        do { accounts = try await api.getAccounts() }
        catch let ApeosError.soapFault(code, _) where code.contains("InternalError") {
            // The account service reports an internal error when device accounting
            // is not enabled, which matches AccountingDeviceType == NONE here.
            accounts = []
            accountsError = nil
            accountingUnavailable = true
        }
        catch { accountsError = error.localizedDescription; accounts = [] }
    }

    func saveAccount(_ a: DeptAccount, isNew: Bool) async {
        accountsError = nil
        if demo != nil {
            if let i = accounts.firstIndex(where: { $0.accountID == a.accountID }) {
                accounts[i] = a
            } else {
                accounts.append(a)
                accounts.sort { $0.accountID < $1.accountID }
            }
            return
        }
        do {
            if isNew { try await api.addAccount(a) } else { try await api.setAccount(a) }
            await loadDirectory()
        } catch { accountsError = error.localizedDescription }
    }

    func deleteAccount(_ a: DeptAccount) async {
        accountsError = nil
        if demo != nil { accounts.removeAll { $0.accountID == a.accountID }; return }
        do { try await api.deleteAccount(id: a.accountID); await loadDirectory() }
        catch { accountsError = error.localizedDescription }
    }

    func saveUser(_ u: DeviceUser, password: String?, isNew: Bool) async {
        usersError = nil
        if demo != nil {
            if let i = users.firstIndex(where: { $0.userID == u.userID }) {
                // Meters are the device's to report, not the editor's to set.
                var edited = u
                edited.usage = users[i].usage
                users[i] = edited
            } else {
                users.append(u)
                users.sort { $0.userID < $1.userID }
            }
            return
        }
        do {
            if isNew { try await api.addUser(u, password: password) }
            else { try await api.setUser(u) }
            await loadDirectory()
            // The device accepts some writes without applying them, so confirm.
            // This device accepts writes it does not apply, so confirm by re-reading.
            let saved = users.first { $0.userID == u.userID }
            if isNew, saved == nil {
                usersError = "The device accepted the request but user '\(u.userID)' is not in its list. It may reject IDs of this length or format."
            } else if let saved, !u.userName.isEmpty, saved.userName != u.userName {
                usersError = "User '\(u.userID)' was saved, but the device did not store the name (it still reads '\(saved.userName)')."
            }
        } catch { usersError = error.localizedDescription }
    }

    /// Applies accounting limits, then re-reads to confirm the device stored them.
    func saveUsageLimits(_ u: DeviceUser, limits: [String: Int]) async {
        usersError = nil
        if demo != nil {
            guard let i = users.firstIndex(where: { $0.userID == u.userID }) else { return }
            users[i].usage = users[i].usage.map { meter in
                guard let wanted = limits[meter.type] else { return meter }
                var updated = meter
                updated.limit = wanted
                updated.remaining = wanted >= UsageMeter.unlimited
                    ? nil : max(0, wanted - meter.used)
                return updated
            }
            return
        }
        do {
            try await api.setUsageLimits(u, limits: limits)
            await loadDirectory()
            if let saved = users.first(where: { $0.userID == u.userID }) {
                for (type, wanted) in limits {
                    let got = saved.usage.first { $0.type == type }?.limit
                    if got != wanted {
                        usersError = "The device did not store the \(type) limit (asked for \(wanted), reads \(got.map(String.init) ?? "none"))."
                        break
                    }
                }
            }
        } catch { usersError = error.localizedDescription }
    }

    @Published var contactsError: String?
    /// Contacts with a favourite write in flight, so the row can show progress and a
    /// second click cannot race the first.
    @Published private(set) var favouritesInFlight: Set<String> = []

    /// Sets or clears a contact's favourite flag and updates the held copy in place.
    ///
    /// The list is patched rather than re-read: the address book is paged twenty at a
    /// time and re-reading the whole book to reflect one star would make the click feel
    /// like a page load. `setFavorite` has already confirmed against the device, so what
    /// it returns is what the printer holds.
    @discardableResult
    func setFavourite(_ contact: Contact, to value: Bool) async -> Bool {
        guard isSignedIn else {
            contactsError = "Signing in as an administrator is required to change favourites."
            return false
        }
        guard !favouritesInFlight.contains(contact.contactId) else { return false }
        contactsError = nil
        favouritesInFlight.insert(contact.contactId)
        defer { favouritesInFlight.remove(contact.contactId) }

        if demo != nil {
            if let i = contacts.firstIndex(where: { $0.contactId == contact.contactId }) {
                contacts[i] = contacts[i].settingFavorite(value)
            }
            return true
        }
        do {
            let stored = try await api.setFavorite(contactId: contact.contactId, to: value)
            if let i = contacts.firstIndex(where: { $0.contactId == contact.contactId }) {
                contacts[i] = contacts[i].settingFavorite(stored)
            }
            if stored != value {
                contactsError = "\(printer.name) did not store the change for \(contact.name)."
                return false
            }
            return true
        } catch {
            contactsError = "\(printer.name): \(error.localizedDescription)"
            return false
        }
    }

    /// Reads the record the device just created and overlays only what the operator
    /// chose. Overlaying the device's own defaults rather than a composed record keeps
    /// every untouched field exactly as the printer set it.
    func applyChosenPermissions(to user: DeviceUser, _ draft: NewUserDraft) async -> Bool {
        guard var wanted = await loadPermissions(for: user) else { return false }
        for (service, value) in draft.access { wanted.access[service] = value }
        if let v = draft.login { wanted.login = v }
        if let v = draft.role { wanted.role = v }
        if let v = draft.group { wanted.group = v }
        return await savePermissions(for: user, wanted) != nil && usersError == nil
    }

    /// Files an email address in this printer's address book. Verified by read-back
    /// inside the client, because the endpoint answers 200 to creates it discards.
    func addContact(named name: String, email: String) async -> Bool {
        contactsError = nil
        if demo != nil {
            let id = String((contacts.compactMap { Int($0.contactId) }.max() ?? 0) + 1)
            contacts.append(Contact(contactId: id, contactType: "PERSON", favorite: false,
                                    displayName: name, lastName: "", firstName: "",
                                    company: "", key: name,
                                    destinations: [Destination(destId: "\(id)-1", type: "MAIL",
                                                               oneTouchKeyId: nil, target: email)]))
            contacts.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            return true
        }
        do {
            try await api.addContact(displayName: name, email: email)
            contacts = (try? await api.addressBook()) ?? contacts
            return true
        } catch {
            contactsError = "\(printer.name): \(error.localizedDescription)"
            return false
        }
    }

    /// Renames a contact or changes its address. Returns whether the printer took it.
    func updateContact(_ c: Contact, displayName: String, company: String,
                       email: String) async -> Bool {
        contactsError = nil
        guard !favouritesInFlight.contains(c.contactId) else { return false }
        favouritesInFlight.insert(c.contactId)
        defer { favouritesInFlight.remove(c.contactId) }
        if demo != nil {
            guard let i = contacts.firstIndex(where: { $0.contactId == c.contactId }) else {
                return false
            }
            contacts[i] = Contact(contactId: c.contactId, contactType: c.contactType,
                                  favorite: c.favorite, displayName: displayName,
                                  lastName: c.lastName, firstName: c.firstName,
                                  company: company, key: displayName,
                                  destinations: [Destination(destId: "\(c.contactId)-1",
                                                             type: "MAIL", oneTouchKeyId: nil,
                                                             target: email)])
            return true
        }
        do {
            try await api.updateContact(id: c.contactId, displayName: displayName,
                                           company: company, email: email)
            contacts = (try? await api.addressBook()) ?? contacts
            return true
        } catch {
            contactsError = "\(printer.name): \(error.localizedDescription)"
            return false
        }
    }

    /// Removes a contact from this printer's address book.
    func deleteContact(_ c: Contact) async -> Bool {
        contactsError = nil
        if demo != nil { contacts.removeAll { $0.contactId == c.contactId }; return true }
        do {
            guard try await api.deleteContact(id: c.contactId) else {
                contactsError = "\(printer.name) still lists \(c.name) after the delete."
                return false
            }
            contacts = (try? await api.addressBook()) ?? contacts
            return true
        } catch {
            contactsError = "\(printer.name): \(error.localizedDescription)"
            return false
        }
    }

    func clearUsage(_ u: DeviceUser) async {
        usersError = nil
        if demo != nil {
            guard let i = users.firstIndex(where: { $0.userID == u.userID }) else { return }
            users[i].usage = users[i].usage.map {
                UsageMeter(type: $0.type, limit: $0.limit, used: 0,
                           remaining: $0.isUnlimited ? nil : $0.limit)
            }
            return
        }
        do { try await api.clearUsageCounters(u); await loadDirectory() }
        catch { usersError = error.localizedDescription }
    }

    /// Deletes a user and, with them, the address book entry that carries their email
    /// address.
    ///
    /// The address is read before the delete, not after: once the record is gone the
    /// device has no way to tell you what it was, and the entry would be left behind
    /// with no way left to identify it.
    func deleteUser(_ u: DeviceUser) async {
        usersError = nil
        if demo != nil {
            users.removeAll { $0.userID == u.userID }
            demoPermissions[u.userID] = nil
            return
        }
        let address = await loadPermissions(for: u)?.mailAddress?
            .trimmingCharacters(in: .whitespaces) ?? ""
        do {
            try await api.deleteUser(id: u.userID, userType: u.userType)
            await loadDirectory()
            if users.contains(where: { $0.userID == u.userID }) {
                usersError = "The device accepted the delete but user '\(u.userID)' is still listed."
                return
            }
        }
        catch { usersError = error.localizedDescription; return }

        // The user is gone either way; a stranded contact is worth reporting but is not
        // a failed deletion, so it is a notice rather than an error.
        guard !address.isEmpty else { return }
        do {
            if try await api.deleteContact(withEmail: address) != nil {
                contacts = (try? await api.addressBook()) ?? contacts
            }
        } catch {
            notice = "\(u.displayName) was deleted, but their address book entry (\(address)) could not be removed from \(printer.name)."
        }
    }

    // MARK: - User permissions

    /// Reads one user's panel permissions and scan-to-email "From" address.
    func loadPermissions(for u: DeviceUser) async -> UserPermissions? {
        usersError = nil
        if demo != nil { return demoPermissions(u.userID) }
        do { return try await api.getUserPermissions(userID: u.userID) }
        catch { usersError = error.localizedDescription; return nil }
    }

    /// The device's numbered permission groups. An empty list means the device does
    /// not offer them, which is not an error worth showing.
    func loadAuthorizationGroups() async -> [AuthorizationGroup] {
        if demo != nil { return DemoFleet.authorizationGroups }
        return (try? await api.authorizationGroups()) ?? []
    }

    /// Applies permissions, then re-reads to confirm the device stored them.
    /// Returns the record as the device now holds it, or nil if the write failed.
    @discardableResult
    func savePermissions(for u: DeviceUser, _ wanted: UserPermissions) async -> UserPermissions? {
        usersError = nil
        if demo != nil { demoPermissions[u.userID] = wanted; return wanted }
        do {
            try await api.setUserPermissions(userID: u.userID, userType: u.userType, wanted)
            let saved = try await api.getUserPermissions(userID: u.userID)
            for (service, permission) in wanted.access where saved.access[service] != permission {
                usersError = "The device did not store the \(service.rawValue.lowercased()) permission (asked for \(permission.label), reads \(saved.access[service]?.label ?? "nothing"))."
                return saved
            }
            if let login = wanted.login, saved.login != login {
                usersError = "The device did not store the login options (asked for \(login.label), reads \(saved.login?.label ?? "nothing"))."
            } else if let role = wanted.role, saved.role != role {
                usersError = "The device did not store the user role (asked for \(role.label), reads \(saved.role?.label ?? "nothing"))."
            } else if let group = wanted.group, saved.group?.number != group.number {
                usersError = "The device did not store the permission group (asked for \(group.label), reads \(saved.group?.label ?? "nothing"))."
            }
            return saved
        } catch { usersError = error.localizedDescription; return nil }
    }

    /// Sets the address a user's scans are sent from, confirming by re-reading.
    @discardableResult
    func saveMailAddress(for u: DeviceUser, _ address: String) async -> UserPermissions? {
        usersError = nil
        if demo != nil {
            var p = demoPermissions(u.userID)
            p.mailAddress = address
            demoPermissions[u.userID] = p
            return p
        }
        do {
            try await api.setUserMailAddress(userID: u.userID, userType: u.userType, address)
            let saved = try await api.getUserPermissions(userID: u.userID)
            if (saved.mailAddress ?? "") != address {
                usersError = "The device accepted the address but reads back '\(saved.mailAddress ?? "")'."
            }
            return saved
        } catch { usersError = error.localizedDescription; return nil }
    }

    func loadAccounting() async {
        guard isSignedIn else { return }
        if let demo { accountingJSON = DemoFleet.accountingJSON(demo); return }
        guard let client else { return }
        let jobs: [(String, () async throws -> Data)] = [
            ("Internal Accounting",  client.internalAccountingRaw),
            ("All Users Management", client.allUsersManagementRaw),
            ("Authorization Groups", client.authorizationGroupsRaw),
            ("Unit Price",           client.unitPriceRaw)
        ]
        for (label, fetch) in jobs {
            do {
                let data = try await fetch()
                accountingJSON[label] = Self.prettyPrint(data)
            } catch {
                accountingJSON[label] = "— \(error.localizedDescription)"
            }
        }
    }

    func saveIdentity(_ edited: DeviceAbout) async {
        errorMessage = nil
        if demo != nil { about = edited; return }
        do {
            try await api.updateAbout(edited)
            about = edited
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Demo

    /// Permissions as edited during a demo run. Held here rather than in the fixture so
    /// each printer keeps its own copy, exactly as the devices do.
    private var demoPermissions: [String: UserPermissions] = [:]

    private func demoPermissions(_ userID: String) -> UserPermissions {
        demoPermissions[userID] ?? DemoFleet.permissions(userID: userID)
    }

    /// A refresh against the fixture.
    ///
    /// The three outcomes are deliberate, and are the three this app exists to tell
    /// apart: a device that cannot be reached, one that answers but serves nothing
    /// without an administrator session, and one that answers fully -- including the
    /// one whose status reads READY while a drum inside it is finished.
    private func demoRefresh(_ demo: DemoFleet.DemoPrinter) async {
        // Long enough that the progress indicator is on screen to be captured, short
        // enough not to be in the way.
        try? await Task.sleep(nanoseconds: 500_000_000)
        lastRefresh = Date()

        guard demo.isReachable else {
            about = nil; status = nil
            supplies = []; counters = []; trays = []; faults = []; jobs = []; contacts = []
            errorMessage = "Could not read: device info: Could not connect to \(printer.host)."
            return
        }
        guard !demo.refusesAnonymousReads || isSignedIn else {
            supplies = []; counters = []; trays = []; faults = []; jobs = []; contacts = []
            about = nil; status = nil
            errorMessage = "This device requires an administrator sign-in to read status. Choose Sign In."
            return
        }

        about = DemoFleet.about(demo)
        status = DemoFleet.status(demo)
        supplies = DemoFleet.supplies(demo)
        counters = DemoFleet.counters(demo)
        trays = DemoFleet.trays(demo)
        faults = DemoFleet.faults(demo)
        jobs = DemoFleet.jobs(demo, max: jobLimit)
        contacts = DemoFleet.contacts(demo)
        errorMessage = nil
    }

    private static func prettyPrint(_ data: Data) -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: obj,
                                options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: pretty, encoding: .utf8) else {
            return String(data: data, encoding: .utf8) ?? "(unreadable)"
        }
        return s
    }
}
