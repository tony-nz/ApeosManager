import SwiftUI

/// The end user's quota monitor.
///
/// Lives in the menu bar (`LSUIElement`), with a popover for the everyday glance and a
/// window for the detail. It signs in only as the person using it and never holds an
/// administrator credential -- the device lets an ordinary user read their own meters,
/// which is what makes a standalone app possible at all.
@main
struct ApeosQuotaApp: App {
    @StateObject private var settings: QuotaSettings
    @StateObject private var monitor: QuotaMonitor

    init() {
        let settings = QuotaSettings()
        _settings = StateObject(wrappedValue: settings)
        _monitor = StateObject(wrappedValue: QuotaMonitor(settings: settings))
    }

    var body: some Scene {
        MenuBarExtra {
            PanelHost(settings: settings, monitor: monitor)
        } label: {
            MenuBarLabel(settings: settings, monitor: monitor)
        }
        .menuBarExtraStyle(.window)

        // The popout: small, floating, one number. Kept fixed-size on purpose -- it is
        // meant to sit in a corner of the screen, not to be arranged.
        Window("Balance", id: WindowID.balance) {
            BalanceHost(settings: settings, monitor: monitor)
        }
        .windowResizability(.contentSize)

        Window("Apeos Quota", id: WindowID.detail) {
            DetailHost(settings: settings, monitor: monitor)
        }
        .defaultSize(width: 620, height: 560)

        Window("Apeos Quota Setup", id: WindowID.signIn) {
            SignInHost(settings: settings, monitor: monitor)
        }
        .windowResizability(.contentSize)
    }
}

enum WindowID {
    static let balance = "balance"
    static let detail = "detail"
    static let signIn = "sign-in"
}

// MARK: - Hosts
//
// The scenes are thin wrappers so each view can reach `openWindow` from the
// environment, and so opening a window also brings the app forward -- an LSUIElement
// app is not activated by SwiftUI on its own, and the window would otherwise appear
// behind whatever the user was working in.

private struct PanelHost: View {
    @ObservedObject var settings: QuotaSettings
    @ObservedObject var monitor: QuotaMonitor
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        QuotaPanel(settings: settings, monitor: monitor,
                   openWindow: { open(WindowID.balance) },
                   openSignIn: { open(WindowID.signIn) })
            .task {
                // Started here rather than in init: the timer should not be running
                // before there is any UI to show its results.
                monitor.start()
            }
    }

    private func open(_ id: String) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        openWindow(id: id)
    }
}

private struct BalanceHost: View {
    @ObservedObject var settings: QuotaSettings
    @ObservedObject var monitor: QuotaMonitor
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        BalanceWindow(settings: settings, monitor: monitor,
                      openDetails: { open(WindowID.detail) },
                      openSignIn: { open(WindowID.signIn) })
    }

    private func open(_ id: String) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        openWindow(id: id)
    }
}

private struct DetailHost: View {
    @ObservedObject var settings: QuotaSettings
    @ObservedObject var monitor: QuotaMonitor
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        QuotaWindow(settings: settings, monitor: monitor, openSignIn: {
            NSApplication.shared.activate(ignoringOtherApps: true)
            openWindow(id: WindowID.signIn)
        })
    }
}

private struct SignInHost: View {
    @ObservedObject var settings: QuotaSettings
    @ObservedObject var monitor: QuotaMonitor
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SignInView(settings: settings) {
            dismiss()
            Task { await monitor.refresh() }
        }
    }
}

// MARK: - Menu bar label

/// What the menu bar shows at rest.
///
/// A countdown is only meaningful where a cap exists, so the label leads with the
/// tightest capped meter when there is one and falls back to total pages used when
/// nothing is capped. With neither -- signed out, or nothing read yet -- it is just the
/// icon, rather than a zero that would read as "no quota left".
private struct MenuBarLabel: View {
    @ObservedObject var settings: QuotaSettings
    @ObservedObject var monitor: QuotaMonitor

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
            if let text { Text(text) }
        }
    }

    private var symbol: String {
        guard settings.isSignedIn else { return "printer" }
        guard let tightest = monitor.fleet.tightest else { return "printer" }
        return tightest.fraction >= 0.95 ? "printer.fill" : "printer"
    }

    private var text: String? {
        guard settings.isSignedIn, monitor.fleet.lastRefreshed != nil else { return nil }
        if let tightest = monitor.fleet.tightest {
            return String(tightest.remaining ?? 0)
        }
        let used = monitor.fleet.totalUsed
        return used > 0 ? String(used) : nil
    }
}
