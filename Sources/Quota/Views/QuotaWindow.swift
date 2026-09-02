import SwiftUI

/// The popped-out view: the same numbers as the menu bar panel, plus the two things
/// there is no room for there -- where each printer stands individually, and a longer
/// history of the user's own jobs.
struct QuotaWindow: View {
    @ObservedObject var settings: QuotaSettings
    @ObservedObject var monitor: QuotaMonitor
    var openSignIn: () -> Void

    private var fleet: FleetQuota { monitor.fleet }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header

                if !settings.isSignedIn {
                    ContentUnavailableView {
                        Label("Not signed in", systemImage: "person.crop.circle.badge.questionmark")
                    } description: {
                        Text("Sign in with your printer user ID and passcode.")
                    } actions: {
                        Button("Sign In", action: openSignIn)
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    totals
                    byPrinter
                    activity
                }
            }
            .padding(24)
        }
        .frame(minWidth: 560, minHeight: 480)
        .navigationTitle("Apeos Quota")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(fleet.userName ?? settings.userID)
                    .font(.title2.weight(.semibold))
                if fleet.userName != nil, !settings.userID.isEmpty {
                    Text(settings.userID).font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if monitor.isRefreshing {
                ProgressView().controlSize(.small)
            } else if let at = fleet.lastRefreshed {
                Text("Updated \(at, format: .relative(presentation: .named))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button { Task { await monitor.refresh() } } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(monitor.isRefreshing)
        }
    }

    private var totals: some View {
        section("Your allowance", subtitle: fleet.incomplete
                ? "\(fleet.failed.count) printer(s) could not be read, so these totals may be low."
                : "Added up across \(fleet.contributing.count) printer(s).") {
            if fleet.meters.isEmpty {
                Text("No meters reported.").font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 12) {
                    ForEach(fleet.limitedMeters + fleet.meters.filter(\.isUnlimited)) { m in
                        MeterRow(meter: m, provisional: fleet.incomplete)
                    }
                }
            }
        }
    }

    private var byPrinter: some View {
        section("By printer", subtitle: nil) {
            VStack(spacing: 10) {
                ForEach(fleet.printers) { p in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(p.printerName).font(.callout.weight(.medium))
                                Text(p.host).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            statusBadge(p)
                        }
                        if let meters = p.meters, !meters.isEmpty {
                            // Compact: the fleet totals above carry the detail, so here
                            // only what this device counted is worth repeating.
                            let ordered = UsageMeter.allTypes.compactMap { t in
                                meters.first { $0.type == t }
                            }
                            ForEach(ordered.filter { $0.used > 0 || !$0.isUnlimited }) { m in
                                HStack {
                                    Text(m.label).font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    Text(m.isUnlimited
                                         ? "\(m.used) used"
                                         : "\(m.used) of \(m.limit ?? 0)")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .padding(10)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    @ViewBuilder
    private func statusBadge(_ p: PrinterQuota) -> some View {
        if let error = p.error {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
        } else if p.noAccount {
            Label("No account", systemImage: "person.slash")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            Label("OK", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
                .labelStyle(.iconOnly)
        }
    }

    private var activity: some View {
        section("Your recent jobs", subtitle: nil) {
            let rows = fleet.contributing.flatMap { p in p.jobs.map { (job: $0, printer: p.printerName) } }
                .sorted { ($0.job.completed ?? .distantPast) > ($1.job.completed ?? .distantPast) }
            if rows.isEmpty {
                Text("Nothing recent under your name.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: 10) {
                            Circle()
                                .fill(row.job.isColour ? Color.accentColor : Color.secondary.opacity(0.5))
                                .frame(width: 6, height: 6)
                            Text(row.job.displayFile).font(.callout).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 8)
                            Text(row.printer).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                            if let s = row.job.sheets, s > 0 {
                                Text("\(s) sh").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            if let when = row.job.completed ?? row.job.created {
                                Text(when, format: .dateTime.day().month().hour().minute())
                                    .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.vertical, 5)
                        Divider()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, subtitle: String?,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            content()
        }
    }
}
