import Foundation
import SwiftUI

/// Reads the signed-in user's own quota across the fleet, on a timer and on demand.
///
/// Three rules govern how this talks to the devices, each of them load-bearing:
///
/// - **Sessions are not held open.** These printers allow only a handful of concurrent
///   sessions, and this app is meant to run on every desk at once. Each refresh signs
///   in, reads, and signs out again; nothing is kept between refreshes.
/// - **Other users' records never leave this file.** The device has no way to return
///   just the caller -- every filter shape it offers is rejected -- so the whole
///   directory and the whole job list come back and are narrowed here, at the boundary.
///   Nothing but the signed-in user's own records is stored, published or displayed.
/// - **One printer's failure is not the fleet's.** Each device is read independently
///   and records its own outcome, so an unreachable printer costs its own numbers
///   rather than the whole refresh.
@MainActor
final class QuotaMonitor: ObservableObject {
    @Published private(set) var fleet = FleetQuota()
    @Published private(set) var isRefreshing = false
    /// Set when every configured printer refused the credentials, which almost always
    /// means the passcode is wrong rather than that five printers broke at once.
    @Published private(set) var credentialsRejected = false

    private let settings: QuotaSettings
    private var ticker: Task<Void, Never>?

    init(settings: QuotaSettings) {
        self.settings = settings
    }

    // MARK: - Scheduling

    func start() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                guard let minutes = self?.settings.refreshMinutes, minutes > 0 else { return }
                try? await Task.sleep(nanoseconds: UInt64(minutes) * 60 * 1_000_000_000)
            }
        }
    }

    func stop() {
        ticker?.cancel()
        ticker = nil
    }

    // MARK: - Refresh

    func refresh() async {
        guard settings.isSignedIn, !settings.printers.isEmpty, !isRefreshing else { return }
        guard let passcode = settings.passcode else { return }

        isRefreshing = true
        defer { isRefreshing = false }

        let userID = settings.userID
        let printers = settings.printers

        // Concurrently, but one session per device: the session limit is per printer,
        // so separate printers do not contend with each other.
        var results: [PrinterQuota] = await withTaskGroup(of: PrinterQuota.self) { group in
            for printer in printers {
                group.addTask {
                    await Self.read(printer: printer, userID: userID, passcode: passcode)
                }
            }
            var out: [PrinterQuota] = []
            for await r in group { out.append(r) }
            return out
        }
        // Restore the user's own ordering, which the task group does not preserve.
        let order = Dictionary(uniqueKeysWithValues: printers.enumerated().map { ($1.id, $0) })
        results.sort { (order[$0.printerID] ?? 0) < (order[$1.printerID] ?? 0) }

        credentialsRejected = !results.isEmpty && results.allSatisfy(\.isCredentialFailure)
        fleet = FleetQuota(printers: results, lastRefreshed: Date())
    }

    /// Reads one printer. Never throws: the outcome, good or bad, is the return value.
    private nonisolated static func read(printer: QuotaPrinter,
                                         userID: String,
                                         passcode: String) async -> PrinterQuota {
        if DemoMode.isEnabled { return await demoRead(printer: printer, userID: userID) }

        var result = PrinterQuota(printerID: printer.id, printerName: printer.name, host: printer.host)
        do {
            let client = try ApeosClient(host: printer.host)
            try await client.login(userID: userID, password: passcode)
            defer { Task { await client.logout() } }

            // The directory arrives whole. Take this user's record and drop the rest
            // here -- nothing downstream should ever see another user's meters.
            guard let me = try await client.getUsers().first(where: { $0.userID == userID }) else {
                result.noAccount = true
                return result
            }
            result.meters = me.usage
            result.userName = me.userName

            // Same again for jobs: the list is device-wide, so it is scanned and
            // narrowed to this user. See jobScanLimit for why the scan is bounded.
            let mine = try await client.jobHistory(max: jobScanLimit)
                .filter { $0.userID == userID }
            result.jobs = Array(mine.prefix(jobsKept))
        } catch {
            result.error = Self.describe(error)
        }
        return result
    }

    /// One printer's answer, from the fixture.
    ///
    /// The same shape a real read produces, failures included: the fleet the demo shows
    /// has a device that cannot be reached and a device this user has no account on,
    /// because "your total is assembled from three of five printers, and here is which
    /// two are missing" is one of the states most worth documenting.
    private nonisolated static func demoRead(printer: QuotaPrinter,
                                             userID: String) async -> PrinterQuota {
        var result = PrinterQuota(printerID: printer.id, printerName: printer.name,
                                  host: printer.host)
        // A real refresh takes a moment, and the spinner is part of the picture.
        try? await Task.sleep(nanoseconds: 450_000_000)

        guard let demo = DemoFleet.printer(host: printer.host) else {
            result.error = "Unavailable"
            return result
        }
        guard demo.isReachable else {
            result.error = "Unreachable"
            return result
        }
        guard demo.holds.contains(userID) else {
            result.noAccount = true
            return result
        }
        result.meters = DemoFleet.meters(userID: userID, on: demo)
        result.userName = DemoFleet.users.first { $0.userID == userID }?.userName ?? ""
        result.jobs = Array(DemoFleet.jobs(demo)
            .filter { $0.userID == userID }
            .prefix(jobsKept))
        return result
    }

    /// How far back through the device-wide job list to look for this user's own jobs.
    ///
    /// The device pages 20 at a time and will not filter by user, so this is a straight
    /// trade: a light printer in a busy office may have nothing in the last hundred
    /// jobs, but raising the bound costs a request per twenty on every printer at every
    /// refresh. Five pages is enough to populate the recent-activity list in practice.
    private static let jobScanLimit = 100
    private static let jobsKept = 25

    private nonisolated static func describe(_ error: Error) -> String {
        switch error {
        case ApeosError.loginFailed:    return "Sign-in refused"
        case ApeosError.http(401, _),
             ApeosError.http(403, _):   return "Sign-in refused"
        case let ApeosError.http(code, _): return "Printer error \(code)"
        case let e as ApeosError:       return e.errorDescription ?? "Unavailable"
        case let e as URLError where e.code == .timedOut:      return "No response"
        case let e as URLError where e.code == .cannotConnectToHost,
             let e as URLError where e.code == .cannotFindHost: return "Unreachable"
        default:                        return "Unavailable"
        }
    }
}

private extension PrinterQuota {
    /// Distinguishes "this printer rejected who you say you are" from any other failure.
    var isCredentialFailure: Bool { error == "Sign-in refused" }
}
