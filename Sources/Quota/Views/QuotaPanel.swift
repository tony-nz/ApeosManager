import SwiftUI

/// The menu bar popover: the whole point of the app in one glance.
///
/// Capped meters come first because they are what can actually run out; uncapped ones
/// are still shown, but as usage rather than as a countdown.
struct QuotaPanel: View {
    @ObservedObject var settings: QuotaSettings
    @ObservedObject var monitor: QuotaMonitor
    var openWindow: () -> Void
    var openSignIn: () -> Void

    private var fleet: FleetQuota { monitor.fleet }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if !settings.isSignedIn {
                signedOutBody
            } else if fleet.lastRefreshed == nil && monitor.isRefreshing {
                loading
            } else if monitor.credentialsRejected {
                message("Your passcode was refused.",
                        detail: "It may have been changed on the printer.",
                        action: ("Sign In Again", openSignIn))
            } else if fleet.contributing.isEmpty {
                message("No account found.",
                        detail: "None of your printers hold an account for “\(settings.userID)”.",
                        action: ("Change Printers", openSignIn))
            } else {
                content
            }

            Divider()
            footer
        }
        .frame(width: 340)
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "printer.dotmatrix")
                .font(.title3)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(fleet.userName ?? (settings.userID.isEmpty ? "Not signed in" : settings.userID))
                    .font(.headline)
                    .lineLimit(1)
                if settings.isSignedIn {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// Says "2 of 3 printers" when some could not be read. Reporting only the number
    /// that answered makes a fleet look smaller than it is, which hides the very fact
    /// that the totals below are a lower bound.
    private var subtitle: String {
        let ok = fleet.contributing.count
        let total = fleet.printers.count
        let printers = total > ok
            ? "\(ok) of \(total) printers"
            : (ok == 1 ? "1 printer" : "\(ok) printers")
        return fleet.userName == nil ? printers : "\(settings.userID) · \(printers)"
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if fleet.incomplete { incompleteNotice }

                let capped = fleet.limitedMeters
                let uncapped = fleet.meters.filter(\.isUnlimited)

                if capped.isEmpty && !uncapped.isEmpty {
                    Text("You have no printing limit set.")
                        .font(.callout).foregroundStyle(.secondary)
                }

                ForEach(capped + uncapped) { meter in
                    MeterRow(meter: meter, provisional: fleet.incomplete)
                }

                // With one printer the totals above already are that printer, and
                // repeating it would be noise. With several, which one is running low
                // is the question the totals cannot answer.
                if fleet.printers.count > 1 {
                    Divider()
                    Text("Printers")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(fleet.printers) { PrinterLine(printer: $0) }
                }

                if !fleet.jobs.isEmpty {
                    Divider()
                    Text("Recent")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(fleet.jobs.prefix(5)) { job in JobRow(job: job) }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .frame(maxHeight: 420)
    }

    private var incompleteNotice: some View {
        Label {
            Text("\(fleet.failed.count) printer\(fleet.failed.count == 1 ? "" : "s") could not be read. Totals may be low.")
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .font(.caption)
        .foregroundStyle(.orange)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var signedOutBody: some View {
        message("Not signed in.",
                detail: "Sign in with your printer user ID and passcode to see your quota.",
                action: ("Sign In", openSignIn))
    }

    private var loading: some View {
        HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
            .padding(.vertical, 28)
    }

    private func message(_ title: String, detail: String,
                         action: (label: String, run: () -> Void)?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.callout.weight(.medium))
            Text(detail).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let action {
                Button(action.label, action: action.run).controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 16)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if monitor.isRefreshing {
                ProgressView().controlSize(.small).scaleEffect(0.7)
                Text("Updating…").font(.caption).foregroundStyle(.secondary)
            } else if let at = fleet.lastRefreshed {
                Text("Updated \(at, format: .relative(presentation: .named))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button { Task { await monitor.refresh() } } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(monitor.isRefreshing || !settings.isSignedIn)
            .help("Refresh now")

            Button(action: openWindow) { Image(systemName: "macwindow.on.rectangle") }
                .buttonStyle(.borderless)
                .help("Keep the balance on screen")

            Menu {
                Button("Printers and Sign In…", action: openSignIn)
                if settings.isSignedIn {
                    Button("Sign Out") { settings.signOut() }
                }
                Divider()
                Button("Quit Apeos Quota") { NSApplication.shared.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

/// One of the user's own jobs, compact enough for the popover.
struct JobRow: View {
    let job: JobRecord

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(job.isColour ? Color.accentColor : Color.secondary.opacity(0.5))
                .frame(width: 6, height: 6)
                .help(job.isColour ? "Colour" : "Black & white")
            Text(job.displayFile)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            if let sheets = job.sheets, sheets > 0 {
                Text("\(sheets)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let when = job.completed ?? job.created {
                Text(when, format: .dateTime.hour().minute())
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// One printer's standing, compact enough for the popover: what it is, and either why
/// it did not answer or how much of the tightest capped meter it has left.
private struct PrinterLine: View {
    let printer: PrinterQuota

    private var tightest: UsageMeter? {
        printer.meters?.filter { !$0.isUnlimited }.max { $0.fraction < $1.fraction }
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(printer.error != nil ? Color.orange
                      : printer.noAccount ? Color.secondary.opacity(0.4) : Color.green)
                .frame(width: 6, height: 6)
            Text(printer.printerName).font(.callout).lineLimit(1)
            Spacer(minLength: 8)
            Group {
                if let error = printer.error {
                    Text(error).foregroundStyle(.orange)
                } else if printer.noAccount {
                    Text("No account").foregroundStyle(.secondary)
                } else if let m = tightest {
                    Text("\((m.remaining ?? 0).formatted()) left").monospacedDigit()
                        .foregroundStyle(m.fraction > 0.9 ? .orange : .secondary)
                } else {
                    Text("No limit").foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .lineLimit(1)
        }
    }
}
