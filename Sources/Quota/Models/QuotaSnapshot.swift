import Foundation

/// What one printer had to say about the signed-in user.
///
/// A user need not exist on every printer in the fleet, and a printer may be off or
/// unreachable, so each result carries its own outcome rather than failing the refresh
/// as a whole. A fleet total assembled from four of five printers is still useful; one
/// that silently omits the fifth without saying so is not.
struct PrinterQuota: Identifiable, Sendable {
    let printerID: UUID
    let printerName: String
    let host: String
    /// Nil when the sign-in itself failed or the device could not be reached.
    var meters: [UsageMeter]?
    /// The user's name as this printer holds it. Devices disagree about whether a name
    /// was ever filled in, so the fleet takes the first non-empty one.
    var userName: String = ""
    var jobs: [JobRecord] = []
    /// Set when this printer could not be read; the reason is shown against it.
    var error: String?
    /// True when the printer answered but holds no account for this user.
    var noAccount: Bool = false

    var id: UUID { printerID }
    var isOK: Bool { error == nil && !noAccount }
}

/// The signed-in user's position across the whole fleet.
///
/// Meters are aggregated per type. Two rules decide the totals, and both are chosen so
/// the figure shown is never rosier than reality:
///
/// - **Used adds up.** Counters are per device, so fleet usage is their sum.
/// - **One unlimited printer makes the type unlimited.** If any printer lets this user
///   print colour without a cap, they are not capped fleet-wide for colour, whatever
///   the other printers say. Summing 9999999 into the total would instead invent an
///   enormous but finite allowance and draw a progress bar against it.
///
/// Printers that could not be read contribute nothing, and `incomplete` says so, so the
/// UI can mark a total as provisional rather than presenting a short count as fact.
struct FleetQuota: Sendable {
    var printers: [PrinterQuota] = []
    var lastRefreshed: Date?

    /// Printers that answered with an account for this user.
    var contributing: [PrinterQuota] { printers.filter(\.isOK) }
    var failed: [PrinterQuota] { printers.filter { $0.error != nil } }
    /// True when at least one printer could not be read, so totals are a lower bound.
    var incomplete: Bool { !failed.isEmpty }

    /// The user's own jobs across the fleet, newest first.
    var jobs: [JobRecord] {
        contributing.flatMap(\.jobs)
            .sorted { ($0.completed ?? $0.created ?? .distantPast) > ($1.completed ?? $1.created ?? .distantPast) }
    }

    /// Fleet totals, in the canonical meter order rather than whatever order the
    /// devices happened to return.
    var meters: [UsageMeter] {
        UsageMeter.allTypes.compactMap { type in
            let parts = contributing.compactMap { $0.meters?.first { $0.type == type } }
            guard !parts.isEmpty else { return nil }

            let used = parts.reduce(0) { $0 + $1.used }
            // See the type comment: an uncapped printer uncaps the fleet for this type.
            if parts.contains(where: \.isUnlimited) {
                return UsageMeter(type: type, limit: nil, used: used, remaining: nil)
            }
            let limit = parts.reduce(0) { $0 + ($1.limit ?? 0) }
            return UsageMeter(type: type, limit: limit, used: used,
                              remaining: max(0, limit - used))
        }
    }

    /// The meters that actually have a cap. These are what a quota app is really about;
    /// everything else is usage reporting.
    var limitedMeters: [UsageMeter] { meters.filter { !$0.isUnlimited } }

    /// The meter closest to running out, which is what the menu bar should lead with.
    /// Nil when nothing is capped -- then there is no balance to count down.
    var tightest: UsageMeter? {
        limitedMeters.max { $0.fraction < $1.fraction }
    }

    /// Total pages the user has put through the fleet, across every meter.
    var totalUsed: Int { meters.reduce(0) { $0 + $1.used } }

    /// The user's name, or nothing if no printer holds one; the caller falls back to
    /// the user ID, which is always known.
    var userName: String? {
        contributing.map(\.userName).first { !$0.isEmpty }
    }
}
