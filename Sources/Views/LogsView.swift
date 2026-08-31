import SwiftUI

enum LogKind: String, CaseIterable, Identifiable {
    case jobs = "Jobs", faults = "Faults"
    var id: String { rawValue }
}

/// Formatting shared by the per-printer and fleet log views.
enum JobFormat {
    static func colour(_ j: JobRecord) -> String {
        j.colour.isEmpty ? "—"
            : j.colour.replacingOccurrences(of: "_", with: " ").capitalized
    }
    static func type(_ j: JobRecord) -> String {
        j.type.replacingOccurrences(of: "_", with: " ").capitalized
    }
    static func state(_ j: JobRecord) -> String {
        j.state.replacingOccurrences(of: "_", with: " ").capitalized
    }
    static func when(_ d: Date?) -> String {
        d.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—"
    }
}

/// Logs for one printer: job history (who printed what) and the fault log.
struct LogsView: View {
    @ObservedObject var vm: DeviceViewModel
    @State private var kind = LogKind.jobs
    @State private var search = ""

    private var jobs: [JobRecord] {
        guard !search.isEmpty else { return vm.jobs }
        let q = search.lowercased()
        return vm.jobs.filter {
            $0.displayUser.lowercased().contains(q) || $0.userID.contains(q)
                || $0.type.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Picker("", selection: $kind) {
                    ForEach(LogKind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 190)
                Spacer()
                if kind == .jobs {
                    HStack(spacing: 4) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search user or type", text: $search)
                            .textFieldStyle(.plain).frame(width: 190)
                    }
                }
                Button("Reload") { Task { await vm.refresh() } }
            }
            .padding(.horizontal, 20).padding(.bottom, 10)

            if kind == .jobs {
                if jobs.isEmpty {
                    if !vm.isSignedIn {
                        ContentUnavailableView("Sign-in required",
                                               systemImage: "person.badge.key",
                                               description: Text("This printer only serves its job history to an administrator. Use Sign In at the top of the window."))
                    } else {
                        ContentUnavailableView("No job history",
                                               systemImage: "doc.text",
                                               description: Text("The device reported no completed jobs."))
                    }
                } else {
                    Table(jobs) {
                        TableColumn("When") { Text(JobFormat.when($0.completed ?? $0.created)) }
                        TableColumn("User") { j in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(j.displayUser)
                                if !j.userID.isEmpty && !j.userName.isEmpty {
                                    Text(j.userID).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                        TableColumn("Type") { Text(JobFormat.type($0)) }
                        TableColumn("Colour") { j in
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(j.isColour ? Color.accentColor : Color.secondary)
                                    .frame(width: 7, height: 7)
                                Text(JobFormat.colour(j))
                            }
                        }
                        TableColumn("Size") { Text($0.mediumSize.isEmpty ? "—" : $0.mediumSize) }
                        TableColumn("Sheets") { j in
                            Text(j.sheets.map(String.init) ?? "—").monospacedDigit()
                        }
                        TableColumn("Impr.") { j in
                            Text(j.impressions.map(String.init) ?? "—").monospacedDigit()
                        }
                        TableColumn("Copies") { j in
                            Text(j.copies.map(String.init) ?? "—").monospacedDigit()
                        }
                        TableColumn("State") { Text(JobFormat.state($0)) }
                        TableColumn("Via") { Text($0.protocolName.isEmpty ? "—" : $0.protocolName) }
                    }
                    .padding(.horizontal, 20)
                }
                HStack {
                    Text(jobSummary).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if vm.loadingMoreJobs { ProgressView().controlSize(.small) }
                    Button("Load 100 More") { Task { await vm.loadMoreJobs() } }
                        .disabled(vm.loadingMoreJobs)
                }
                .padding(.horizontal, 20).padding(.vertical, 12)
            } else {
                if vm.faults.isEmpty {
                    if !vm.isSignedIn {
                        ContentUnavailableView("Sign-in required",
                                               systemImage: "person.badge.key",
                                               description: Text("This printer only serves its fault log to an administrator."))
                    } else {
                        ContentUnavailableView("No faults recorded",
                                               systemImage: "checkmark.seal",
                                               description: Text("This printer's fault history is empty."))
                    }
                } else {
                    Table(vm.faults) {
                        TableColumn("When") { f in
                            Text(f.date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—")
                        }
                        TableColumn("Code") { f in Text(f.code).monospaced() }
                        TableColumn("Occurrences") { f in
                            let n = vm.faults.filter { $0.code == f.code }.count
                            Text(n > 1 ? "\(n)× on this printer" : "once")
                                .font(.caption).foregroundStyle(n > 1 ? Color.orange : Color.secondary)
                        }
                        TableColumn("Impressions") { f in
                            Text(f.volume.map { "\($0)" } ?? "—").monospacedDigit()
                        }
                    }
                    .padding(.horizontal, 20)
                }
                HStack {
                    Text("\(vm.faults.count) entries · codes are Fujifilm service codes; the device does not publish descriptions for them")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 20).padding(.vertical, 12)
            }
        }
    }

    private var jobSummary: String {
        let colour = jobs.filter(\.isColour).count
        let sheets = jobs.compactMap(\.sheets).reduce(0, +)
        let impr = jobs.compactMap(\.impressions).reduce(0, +)
        return "\(jobs.count) jobs · \(colour) colour, \(jobs.count - colour) mono · \(sheets) sheets, \(impr) impressions"
    }
}
