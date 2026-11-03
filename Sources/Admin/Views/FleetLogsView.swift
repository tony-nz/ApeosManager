import SwiftUI

/// Job and fault logs across every printer.
struct FleetLogsView: View {
    @EnvironmentObject var fleet: Fleet
    @State private var kind = LogKind.jobs
    @State private var search = ""
    @State private var onlyRecent = true

    // Filters. Nil means "all". The printer filter applies to both tabs.
    @State private var printerFilter: UUID?
    /// A `userKey`, not a name: two people can share a name, and the ID is what the
    /// printers themselves tell them apart by.
    @State private var userFilter: String?
    @State private var typeFilter: String?
    @State private var colourFilter: ColourFilter?
    @State private var sizeFilter: String?
    @State private var stateFilter: String?
    @State private var period = Period.all
    @State private var loadingMore = false

    private enum ColourFilter: String, CaseIterable, Identifiable {
        case colour = "Colour", mono = "Mono"
        var id: String { rawValue }
    }

    private enum Period: String, CaseIterable, Identifiable {
        case all = "All Time", today = "Today", week = "Last 7 Days"
        case month = "Last 30 Days", quarter = "Last 90 Days"
        var id: String { rawValue }

        var cutoff: Date? {
            let calendar = Calendar.current
            switch self {
            case .all:     return nil
            case .today:   return calendar.startOfDay(for: Date())
            case .week:    return calendar.date(byAdding: .day, value: -7, to: Date())
            case .month:   return calendar.date(byAdding: .day, value: -30, to: Date())
            case .quarter: return calendar.date(byAdding: .day, value: -90, to: Date())
            }
        }
    }

    private struct JobRow: Identifiable {
        let id: String
        let printerID: UUID
        let printer: String
        let job: JobRecord
    }
    private struct FaultRow: Identifiable {
        let id: String
        let printer: String
        let entry: FaultEntry
    }

    private static func sizeLabel(_ job: JobRecord) -> String {
        job.mediumSize.isEmpty ? "—" : job.mediumSize
    }

    private var allJobRows: [JobRow] {
        fleet.ordered().flatMap { vm in
            vm.jobs.map {
                JobRow(id: "\(vm.printer.id)-\($0.jobID)", printerID: vm.printer.id,
                       printer: vm.printer.name, job: $0)
            }
        }
    }

    private static func userKey(_ job: JobRecord) -> String {
        job.userID.isEmpty ? job.displayUser : job.userID
    }

    /// One entry per person. The ID is shown only where a name would be ambiguous, which
    /// keeps a long menu readable; the selected user stays listed even after a refresh
    /// drops their last job, so the menu always has an entry for what is selected.
    private var userChoices: [UserChoice] {
        var names: [String: String] = [:]
        for row in allJobRows {
            let key = Self.userKey(row.job)
            if names[key] == nil || names[key] == key { names[key] = row.job.displayUser }
        }
        if let userFilter, names[userFilter] == nil { names[userFilter] = userFilter }

        var nameCounts: [String: Int] = [:]
        for name in names.values { nameCounts[name, default: 0] += 1 }
        let list = names.map { key, name in
            UserChoice(key: key, label: (nameCounts[name] ?? 0) > 1 ? "\(name) (\(key))" : name)
        }
        return list.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }

    private var jobFiltersActive: Bool {
        printerFilter != nil || userFilter != nil || typeFilter != nil || colourFilter != nil
            || sizeFilter != nil || stateFilter != nil || period != .all
    }

    /// A filter's choices are what the loaded jobs contain, plus the current selection,
    /// so a refresh that drops the last matching job cannot leave the menu with no entry
    /// for what is selected.
    private func choices(_ label: (JobRecord) -> String, selected: String?) -> [String] {
        var values = Set(allJobRows.map { label($0.job) })
        if let selected { values.insert(selected) }
        return values.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private func clearJobFilters() {
        printerFilter = nil
        userFilter = nil
        typeFilter = nil
        colourFilter = nil
        sizeFilter = nil
        stateFilter = nil
        period = .all
    }

    private var jobRows: [JobRow] {
        var all = allJobRows
        if let printerFilter { all = all.filter { $0.printerID == printerFilter } }
        if let userFilter { all = all.filter { Self.userKey($0.job) == userFilter } }
        if let typeFilter { all = all.filter { JobFormat.type($0.job) == typeFilter } }
        if let colourFilter { all = all.filter { $0.job.isColour == (colourFilter == .colour) } }
        if let sizeFilter { all = all.filter { Self.sizeLabel($0.job) == sizeFilter } }
        if let stateFilter { all = all.filter { JobFormat.state($0.job) == stateFilter } }
        if let cutoff = period.cutoff {
            all = all.filter { ($0.job.completed ?? $0.job.created ?? .distantPast) >= cutoff }
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
        if let printerName = fleet.ordered().first(where: { $0.printer.id == printerFilter })?.printer.name {
            all = all.filter { $0.printer == printerName }
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
        let key: String
        let name: String
        let sheets: Int
        var id: String { key }
    }

    struct UserChoice: Identifiable {
        let key: String
        let label: String
        var id: String { key }
    }

    /// Who is printing the most, across the fleet. Built step by step: the equivalent
    /// single chained expression exceeds the Swift type-checker's time budget.
    private var topUsers: [UserTotal] {
        var totals: [String: Int] = [:]
        var names: [String: String] = [:]
        for row in jobRows {
            let name = row.job.displayUser
            guard name != "—" else { continue }
            let key = Self.userKey(row.job)
            totals[key, default: 0] += row.job.sheets ?? 0
            if names[key] == nil || names[key] == key { names[key] = name }
        }
        let list = totals.map { UserTotal(key: $0.key, name: names[$0.key] ?? $0.key, sheets: $0.value) }
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

    /// Only the latest jobs are read from each printer, so a period can reach back past
    /// what is loaded. Its totals would then look complete and be low, so say which
    /// printers are short rather than letting the figure stand unqualified.
    private var cutShortPrinters: [DeviceViewModel] {
        guard let cutoff = period.cutoff else { return [] }
        return fleet.ordered().filter { vm in
            guard printerFilter == nil || vm.printer.id == printerFilter,
                  vm.jobs.count >= vm.jobLimit else { return false }
            let oldest = vm.jobs.compactMap { $0.completed ?? $0.created }.min()
            return (oldest ?? .distantPast) > cutoff
        }
    }

    private func loadMore(_ devices: [DeviceViewModel]) async {
        loadingMore = true
        defer { loadingMore = false }
        await withTaskGroup(of: Void.self) { group in
            for vm in devices { group.addTask { await vm.loadMoreJobs() } }
        }
    }

    private var printerMenu: some View {
        Picker("Printer", selection: $printerFilter) {
            Text("All Printers").tag(UUID?.none)
            Divider()
            ForEach(fleet.ordered(), id: \.printer.id) { vm in
                Text(vm.printer.name).tag(Optional(vm.printer.id))
            }
        }
        .labelsHidden().fixedSize()
    }

    private func stringMenu(_ all: String, _ selection: Binding<String?>,
                            _ values: [String]) -> some View {
        Picker(all, selection: selection) {
            Text(all).tag(String?.none)
            Divider()
            ForEach(values, id: \.self) { Text($0).tag(Optional($0)) }
        }
        .labelsHidden().fixedSize()
    }

    private var userMenu: some View {
        Picker("All Users", selection: $userFilter) {
            Text("All Users").tag(String?.none)
            Divider()
            ForEach(userChoices) { Text($0.label).tag(Optional($0.key)) }
        }
        .labelsHidden().fixedSize()
    }

    private var colourMenu: some View {
        Picker("All Colours", selection: $colourFilter) {
            Text("All Colours").tag(ColourFilter?.none)
            Divider()
            ForEach(ColourFilter.allCases) { Text($0.rawValue).tag(Optional($0)) }
        }
        .labelsHidden().fixedSize()
    }

    private var periodMenu: some View {
        Picker("Period", selection: $period) {
            ForEach(Period.allCases) { Text($0.rawValue).tag($0) }
        }
        .labelsHidden().fixedSize()
    }

    @ViewBuilder private var clearFilters: some View {
        if jobFiltersActive {
            Button("Clear") { clearJobFilters() }
                .buttonStyle(.link)
        }
    }

    /// One row when the window has room, two when it does not. A selected printer or
    /// user can be a long name, and these menus size to what they show.
    private var jobFilterBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                printerMenu
                userMenu
                stringMenu("All Types", $typeFilter, choices(JobFormat.type, selected: typeFilter))
                colourMenu
                stringMenu("All Sizes", $sizeFilter, choices(Self.sizeLabel, selected: sizeFilter))
                stringMenu("All States", $stateFilter, choices(JobFormat.state, selected: stateFilter))
                periodMenu
                clearFilters
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    printerMenu
                    userMenu
                    periodMenu
                    clearFilters
                    Spacer(minLength: 0)
                }
                HStack(spacing: 8) {
                    stringMenu("All Types", $typeFilter, choices(JobFormat.type, selected: typeFilter))
                    colourMenu
                    stringMenu("All Sizes", $sizeFilter, choices(Self.sizeLabel, selected: sizeFilter))
                    stringMenu("All States", $stateFilter, choices(JobFormat.state, selected: stateFilter))
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 20).padding(.bottom, 10)
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
                jobFilterBar
                let short = cutShortPrinters
                if !short.isEmpty {
                    HStack(spacing: 8) {
                        Label("Only the latest jobs are loaded for "
                              + short.map(\.printer.name).joined(separator: ", ")
                              + ", so this period may be missing older jobs.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Load More") { Task { await loadMore(short) } }
                            .controlSize(.small)
                            .disabled(loadingMore)
                        if loadingMore { ProgressView().controlSize(.small) }
                        Spacer()
                    }
                    .padding(.horizontal, 20).padding(.bottom, 8)
                }
                if let note = unreadableNote {
                    Label(note, systemImage: "person.badge.key")
                        .font(.caption).foregroundStyle(.orange)
                        .padding(.horizontal, 20).padding(.bottom, 8)
                }
                if !topUsers.isEmpty {
                    HStack(spacing: 10) {
                        Text("Most sheets:").font(.caption).foregroundStyle(.secondary)
                        ForEach(topUsers) { u in
                            Button {
                                userFilter = userFilter == u.key ? nil : u.key
                            } label: {
                                Text("\(u.name) \(u.sheets)")
                                    .font(.caption)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Capsule().fill(Color.accentColor
                                        .opacity(userFilter == u.key ? 0.4 : 0.14)))
                            }
                            .buttonStyle(.plain)
                            .help(userFilter == u.key ? "Show all users" : "Show only \(u.name)")
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
                .overlay {
                    if jobRows.isEmpty, jobFiltersActive || !search.isEmpty {
                        Text("No jobs match these filters.").foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 20)

                HStack {
                    Text(jobSummary).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 20).padding(.vertical, 10)
            } else {
                HStack(spacing: 8) {
                    printerMenu
                    Spacer()
                }
                .padding(.horizontal, 20).padding(.bottom, 10)
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
        let rows = jobRows
        let colour = rows.filter(\.job.isColour).count
        let sheets = rows.compactMap(\.job.sheets).reduce(0, +)
        let total = allJobRows.count
        let count = rows.count == total ? "\(total) jobs" : "\(rows.count) of \(total) jobs"
        return "\(count) · \(colour) colour, \(rows.count - colour) mono · \(sheets) sheets"
    }
}
