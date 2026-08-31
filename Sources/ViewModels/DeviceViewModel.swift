import Foundation
import SwiftUI

@MainActor
final class DeviceViewModel: ObservableObject {
    let printer: Printer
    private let client: ApeosClient

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

    init(printer: Printer, password: String? = nil) {
        self.printer = printer
        self.storedPassword = password
        self.client = ApeosClient(host: printer.host)
    }

    /// Signs in (when a password is held) and loads everything. Devices differ over
    /// whether /home/api is readable anonymously, so signing in first is the only
    /// order that works across the fleet.
    func connect() async {
        guard !isConnected else { return }
        isConnected = true
        if let storedPassword, !storedPassword.isEmpty, !isSignedIn {
            await signIn(password: storedPassword)
        } else {
            if passwordLocked {
                notice = "A saved password exists but this build of the app cannot read it — the app's code signature changed. Sign in once to store it again."
            }
            await refresh()
        }
    }

    /// Pulls a deeper slice of job history without re-reading everything else.
    func loadMoreJobs() async {
        jobLimit += 100
        loadingMoreJobs = true
        defer { loadingMoreJobs = false }
        do { jobs = try await client.jobHistory(max: jobLimit) }
        catch { errorMessage = error.localizedDescription }
    }

    func reconnect() async {
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

        await run("device info")  { about    = try await client.about() }
        await run("status")       { status   = try await client.status() }
        await run("supplies")     { supplies = try await client.supplies().supplies }
        await run("counters")     { counters = try await client.counters().usageCounters }
        await run("trays")        { trays    = try await client.trays().paperTrays }
        await run("fault log")    { faults   = try await client.faultHistory().faultHistory }
        await run("job history")  { jobs     = try await client.jobHistory(max: jobLimit) }
        await run("address book") { contacts = try await client.addressBook() }

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
        do {
            let result = try await client.login(userID: printer.adminUser, password: password)
            isSignedIn = true
            notice = result.passwordChangeRequired != nil
                ? "The device is requesting an administrator password change."
                : nil
            // Devices that refuse anonymous reads only return data once signed in.
            await refresh()
            await loadAccounting()
            await loadDirectory()
        } catch {
            isSignedIn = false
            errorMessage = error.localizedDescription
        }
    }

    func signOut() async {
        await client.logout()
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

        // Fetched independently: a failure in one must not suppress the other.
        do { users = try await client.getUsers() }
        catch { usersError = error.localizedDescription; users = [] }

        do { accounts = try await client.getAccounts() }
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
        do {
            if isNew { try await client.addAccount(a) } else { try await client.setAccount(a) }
            await loadDirectory()
        } catch { accountsError = error.localizedDescription }
    }

    func deleteAccount(_ a: DeptAccount) async {
        accountsError = nil
        do { try await client.deleteAccount(id: a.accountID); await loadDirectory() }
        catch { accountsError = error.localizedDescription }
    }

    func saveUser(_ u: DeviceUser, password: String?, isNew: Bool) async {
        usersError = nil
        do {
            if isNew { try await client.addUser(u, password: password) }
            else { try await client.setUser(u) }
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
        do {
            try await client.setUsageLimits(u, limits: limits)
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

    func clearUsage(_ u: DeviceUser) async {
        usersError = nil
        do { try await client.clearUsageCounters(u); await loadDirectory() }
        catch { usersError = error.localizedDescription }
    }

    func deleteUser(_ u: DeviceUser) async {
        usersError = nil
        do {
            try await client.deleteUser(id: u.userID, userType: u.userType)
            await loadDirectory()
            if users.contains(where: { $0.userID == u.userID }) {
                usersError = "The device accepted the delete but user '\(u.userID)' is still listed."
            }
        }
        catch { usersError = error.localizedDescription }
    }

    func loadAccounting() async {
        guard isSignedIn else { return }
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
        do {
            try await client.updateAbout(edited)
            about = edited
        } catch {
            errorMessage = error.localizedDescription
        }
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
