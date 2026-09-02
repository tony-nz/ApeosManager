import SwiftUI

/// The PaperCut-style balance window: small, floating, one number.
///
/// This is the popout people leave on screen all day, so the headline stays a single
/// figure; anything needing reading rather than glancing lives behind "Details…".
///
/// Which number: the meter closest to running out, because that is the one that will
/// stop you printing. It is named underneath, so a user with several caps can see which
/// figure they are looking at rather than guessing.
///
/// With more than one printer the headline alone is ambiguous -- a fleet total cannot
/// say which device is the one about to refuse you -- so each printer gets a line of
/// its own, tinted by how much it has left. One printer gets no such list, because the
/// total already is that printer.
struct BalanceWindow: View {
    @ObservedObject var settings: QuotaSettings
    @ObservedObject var monitor: QuotaMonitor
    var openDetails: () -> Void
    var openSignIn: () -> Void

    private var fleet: FleetQuota { monitor.fleet }

    private static let number: NumberFormatter = {
        let f = NumberFormatter(); f.numberStyle = .decimal; return f
    }()
    private func fmt(_ n: Int) -> String {
        Self.number.string(from: NSNumber(value: n)) ?? String(n)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Balance")
                .font(.caption)
                .foregroundStyle(.secondary)

            if !settings.isSignedIn {
                Text("—").font(.system(size: 34, weight: .semibold, design: .rounded))
                Text("Not signed in").font(.caption).foregroundStyle(.secondary)
            } else {
                Text(figure)
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if showsPrinters {
                Divider().padding(.vertical, 8)
                VStack(spacing: 4) {
                    ForEach(fleet.printers) { PrinterChip(printer: $0, format: fmt) }
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                Text(fleet.userName ?? (settings.userID.isEmpty ? "—" : settings.userID))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if monitor.isRefreshing {
                    ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 12)
                }
                Button(settings.isSignedIn ? "Details…" : "Sign In") {
                    settings.isSignedIn ? openDetails() : openSignIn()
                }
                .controlSize(.small)
            }
        }
        .padding(12)
        .frame(width: showsPrinters ? 260 : 220, height: windowHeight, alignment: .leading)
        .background(WindowConfigurator { window in
            // PaperCut's client sits above whatever you are working in; a balance you
            // have to go looking for is one you stop looking at.
            window.level = .floating
            window.titlebarAppearsTransparent = true
            window.standardWindowButton(.zoomButton)?.isEnabled = false
            window.isMovableByWindowBackground = true
        })
    }

    private var showsPrinters: Bool {
        settings.isSignedIn && fleet.printers.count > 1
    }

    /// Grown to fit the rows rather than scrolled: this window is deliberately small and
    /// a scroller inside 260 points is worse than a slightly taller window. A fleet
    /// large enough to overflow belongs in Details, so the list stops at five.
    private var windowHeight: CGFloat {
        guard showsPrinters else { return 118 }
        return 118 + 9 + CGFloat(min(fleet.printers.count, 5)) * 26
    }

    /// The headline figure: pages left where there is a cap, pages used where there is
    /// not. Never a bare "0" for an uncapped meter, which would read as "you are out".
    private var figure: String {
        if fleet.lastRefreshed == nil { return "…" }
        if let tightest = fleet.tightest { return fmt(tightest.remaining ?? 0) }
        return fmt(fleet.totalUsed)
    }

    private var caption: String {
        if fleet.lastRefreshed == nil { return "Checking…" }
        if let tightest = fleet.tightest {
            return "\(tightest.label) remaining\(fleet.incomplete ? " (partial)" : "")"
        }
        return fleet.meters.isEmpty ? "No meters reported" : "pages used · no limit set"
    }

    private var tint: Color {
        guard let f = fleet.tightest?.fraction else { return .primary }
        switch f {
        case 0.95...: return .red
        case 0.80...: return .orange
        default:      return .primary
        }
    }
}

/// One printer's line: a status dot, its name, and what it has left, on a wash of the
/// same colour so the state reads before any of the text does.
private struct PrinterChip: View {
    let printer: PrinterQuota
    let format: (Int) -> String

    private var tightest: UsageMeter? {
        printer.meters?.filter { !$0.isUnlimited }.max { $0.fraction < $1.fraction }
    }

    private var tint: Color {
        if printer.error != nil { return .orange }
        if printer.noAccount { return .secondary }
        guard let f = tightest?.fraction else { return .green }
        switch f {
        case 0.95...: return .red
        case 0.80...: return .orange
        default:      return .green
        }
    }

    private var trailing: String {
        if let error = printer.error { return error }
        if printer.noAccount { return "No account" }
        guard let m = tightest else { return "No limit" }
        return "\(format(m.remaining ?? 0)) left"
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(printer.printerName)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            Text(trailing)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(tint.opacity(0.25)))
    }
}

/// Reaches the `NSWindow` behind a SwiftUI scene. macOS 14 has no `.windowLevel` scene
/// modifier, so floating behaviour has to be set on the window itself.
struct WindowConfigurator: NSViewRepresentable {
    let configure: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // The window is not attached until after this returns.
        DispatchQueue.main.async {
            if let window = view.window { configure(window) }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
