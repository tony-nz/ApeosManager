import SwiftUI

/// Job and fault logs across every printer.
struct FleetLogsView: View {
    @EnvironmentObject var fleet: Fleet
    @State private var kind = LogKind.jobs
    @State private var search = ""
    @State private var onlyRecent = true

    private struct JobRow: Identifiable {
        let id: String
        let printer: String
        let job: JobRecord
    }
    private struct FaultRow: Identifiable {
        let id: String
        let printer: String
        let entry: FaultEntry
    }

    private var jobRows: [JobRow] {
        var all = fleet.ordered().flatMap { vm in
            vm.jobs.map { JobRow(id: "\(vm.printer.id)-\($0.jobID)", printer: vm.printer.name, job: $0) }
        }
        if !search.isEmpty {
            let q = search.lowercased()
            all = all.filter {
                $0.job.displayUser.lowercased().contains(q) || $0.job.userID.contains(q)
                    || $0.printer.lowercased().contains(q) || $0.job.type.lowercased().contains(q)
            }
        }
        return all.sorted {
            ($0.job.completed ?? $0.job.created ?? .distantPast) >
            ($1.job.completed ?? $1.job.created ?? .distantPast)
        }
    }

    private var faultRows: [FaultRow] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -90, to: Date())
        var all = fleet.ordered().flatMap { vm in
            vm.faults.map { FaultRow(id: "\(vm.printer.id)-\($0.id)", printer: vm.printer.name, entry: $0) }
        }
        if onlyRecent, let cutoff {
            all = all.filter { ($0.entry.date ?? .distantPast) >= cutoff }
        }
        if !search.isEmpty {
            let q = search.lowercased()
            all = all.filter { $0.entry.code.contains(q) || $0.printer.lowercased().contains(q) }
        }
        return all.sorted { ($0.entry.date ?? .distantPast) > ($1.entry.date ?? .distantPast) }
    }

    /// Codes seen more than once are the ones worth chasing with a service call.
    struct CodeCount: Identifiable {
        let code: String
        let count: Int
        var id: String { code }
    }

    private var repeated: [CodeCount] {
        var counts: [String: Int] = [:]
        for row in faultRows { counts[row.entry.code, default: 0] += 1 }
        let list = counts.filter { $0.value > 1 }.map { CodeCount(code: $0.key, count: $0.value) }
        return Array(list.sorted { $0.count > $1.count }.prefix(6))
    }

    struct UserTotal: Identifiable {
        let name: String
        let sheets: Int
        var id: String { name }
    }

    /// Who is printing the most, across the fleet. Built step by step: the equivalent
    /// single chained expression exceeds the Swift type-checker's time budget.
    private var topUsers: [UserTotal] {
        var totals: [String: Int] = [:]
        for row in jobRows {
            let name = row.job.displayUser
            guard name != "—" else { continue }
            totals[name, default: 0] += row.job.sheets ?? 0
        }
        let list = totals.map { UserTotal(name: $0.key, sheets: $0.value) }
        let sorted = list.sorted { $0.sheets > $1.sheets }
        return Array(sorted.prefix(5))
    }

    /// Printers that could not be read contribute nothing to these logs; say so rather
    /// than presenting a partial fleet view as if it were complete.
    private var unreadableNote: String? {
        let out = fleet.ordered().filter { !$0.isSignedIn && $0.jobs.isEmpty && $0.faults.isEmpty }
        guard !out.isEmpty else { return nil }
        return "Not included (needs administrator sign-in): " + out.map(\.printer.name).joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Logs").font(.title2).bold()
                Picker("", selection: $kind) {
                    ForEach(LogKind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 180)
                if fleet.isLoadingAll { ProgressView().controlSize(.small) }
                Spacer()
                if kind == .faults {
                    Toggle("Last 90 days", isOn: $onlyRecent).toggleStyle(.checkbox)
                }
                Button { Task { await fleet.refreshAll() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 8)

            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(kind == .jobs ? "Search user, printer or type" : "Search code or printer",
                          text: $search)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 20).padding(.bottom, 10)

            if kind == .jobs {
                if let note = unreadableNote {
                    Label(note, systemImage: "person.badge.key")
                        .font(.caption).foregroundStyle(.orange)
                        .padding(.horizontal, 20).padding(.bottom, 8)
                }
                if !topUsers.isEmpty {
                    HStack(spacing: 10) {
                        Text("Most sheets:").font(.caption).foregroundStyle(.secondary)
                        ForEach(topUsers) { u in
                            Text("\(u.name) \(u.sheets)")
                                .font(.caption)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 20).padding(.bottom, 8)
                }

                Table(jobRows) {
                    TableColumn("When") { Text(JobFormat.when($0.job.completed ?? $0.job.created)) }
                    TableColumn("Printer") { Text($0.printer) }
                    TableColumn("User") { r in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(r.job.displayUser)
                            if !r.job.userID.isEmpty && !r.job.userName.isEmpty {
                                Text(r.job.userID).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    TableColumn("Type") { Text(JobFormat.type($0.job)) }
                    TableColumn("Colour") { r in
                        HStack(spacing: 4) {
                            Circle().fill(r.job.isColour ? Color.accentColor : Color.secondary)
                                .frame(width: 7, height: 7)
                            Text(JobFormat.colour(r.job))
                        }
                    }
                    TableColumn("Size") { Text($0.job.mediumSize.isEmpty ? "—" : $0.job.mediumSize) }
                    TableColumn("Sheets") { r in
                        Text(r.job.sheets.map(String.init) ?? "—").monospacedDigit()
                    }
                    TableColumn("Impr.") { r in
                        Text(r.job.impressions.map(String.init) ?? "—").monospacedDigit()
                    }
                    TableColumn("State") { Text(JobFormat.state($0.job)) }
                }
                .padding(.horizontal, 20)

                HStack {
                    Text(jobSummary).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 20).padding(.vertical, 10)
            } else {
                if !repeated.isEmpty {
                    HStack(spacing: 10) {
                        Text("Recurring:").font(.caption).foregroundStyle(.secondary)
                        ForEach(repeated) { r in
                            Text("\(r.code) ×\(r.count)")
                                .font(.caption).monospaced()
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(Color.orange.opacity(0.15)))
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 20).padding(.bottom, 8)
                }

                Table(faultRows) {
                    TableColumn("When") { r in
                        Text(r.entry.date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—")
                    }
                    TableColumn("Printer") { Text($0.printer) }
                    TableColumn("Code") { Text($0.entry.code).monospaced() }
                    TableColumn("Impressions") { r in
                        Text(r.entry.volume.map { "\($0)" } ?? "—").monospacedDigit()
                    }
                }
                .padding(.horizontal, 20)

                HStack {
                    Text("\(faultRows.count) entries · codes are Fujifilm service codes; the device does not publish descriptions")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 20).padding(.vertical, 10)
            }
        }
        .task { await fleet.connectAll() }
    }

    private var jobSummary: String {
        let colour = jobRows.filter(\.job.isColour).count
        let sheets = jobRows.compactMap(\.job.sheets).reduce(0, +)
        return "\(jobRows.count) jobs · \(colour) colour, \(jobRows.count - colour) mono · \(sheets) sheets"
    }
}
