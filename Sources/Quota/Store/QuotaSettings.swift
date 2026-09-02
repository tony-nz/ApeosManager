import Foundation

/// A printer the user's quota is read from. Deliberately thinner than the fleet
/// manager's `Printer`: there is no administrator account here to record.
struct QuotaPrinter: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    var host: String
}

/// Everything the user app remembers between launches.
///
/// The passcode is the one thing that never lands in UserDefaults. It goes to the
/// keychain, under this app's own bundle identifier, so it is stored apart from the
/// administrator passwords the fleet manager keeps.
@MainActor
final class QuotaSettings: ObservableObject {
    @Published var printers: [QuotaPrinter] = [] { didSet { savePrinters() } }
    @Published var userID: String = "" { didSet { save(userID, Key.userID) } }
    /// Minutes between automatic refreshes. Meters move slowly and every refresh costs
    /// the device a sign-in, so the default is deliberately unhurried.
    @Published var refreshMinutes: Int = 15 { didSet { save(refreshMinutes, Key.refresh) } }

    private let defaults = UserDefaults.standard

    /// Every setting here writes through on change, so a demo that let one through
    /// would rewrite the real configuration merely by opening the settings window.
    private func save(_ value: Any, _ key: String) {
        guard !DemoMode.isEnabled else { return }
        defaults.set(value, forKey: key)
    }

    private enum Key {
        static let printers = "quota.printers.v1"
        static let userID   = "quota.userID"
        static let refresh  = "quota.refreshMinutes"
    }
    /// One account key, not one per user: signing in as somebody else replaces the
    /// stored passcode rather than leaving the previous user's behind.
    private static let passcodeAccount = "signed-in-user"

    init() {
        // A demo run is signed in to the fixture from the first launch: the app is a
        // menu bar item, and a first-run sign-in sheet is not the picture anyone came
        // to see. The real settings are neither read nor written -- see `save`.
        if DemoMode.isEnabled {
            printers = DemoFleet.printers.map { QuotaPrinter(id: $0.id, name: $0.name, host: $0.host) }
            userID = DemoFleet.demoUserID
            refreshMinutes = 15
            return
        }
        if let data = defaults.data(forKey: Key.printers),
           let decoded = try? JSONDecoder().decode([QuotaPrinter].self, from: data) {
            printers = decoded
        }
        userID = defaults.string(forKey: Key.userID) ?? ""
        let stored = defaults.integer(forKey: Key.refresh)
        refreshMinutes = stored > 0 ? stored : 15
    }

    private func savePrinters() {
        guard !DemoMode.isEnabled else { return }
        guard let data = try? JSONEncoder().encode(printers) else { return }
        defaults.set(data, forKey: Key.printers)
    }

    // MARK: - Credentials

    /// The keychain is not consulted in a demo.
    ///
    /// This app stores the user's passcode under one fixed account name, so a demo run
    /// on the machine of somebody who uses the app for real would read *their* passcode
    /// -- and, without the guard in `ApeosClient.init`, send it to whatever address the
    /// fixture happened to name. A placeholder is returned instead, which is enough for
    /// `isSignedIn` and reaches nothing.
    var passcode: String? {
        DemoMode.isEnabled ? DemoMode.placeholderPasscode : Keychain.get(account: Self.passcodeAccount)
    }

    /// True when a passcode is stored but this build cannot read it, which happens
    /// whenever the app's code signature changes. Worth distinguishing from "not signed
    /// in", because the remedy is different: sign in again rather than wonder why.
    var passcodeLocked: Bool {
        guard !DemoMode.isEnabled else { return false }
        if case .denied = Keychain.lookup(account: Self.passcodeAccount) { return true }
        return false
    }

    var isSignedIn: Bool { !userID.isEmpty && passcode != nil }

    func signIn(userID: String, passcode: String) {
        self.userID = userID
        guard !DemoMode.isEnabled else { return }
        Keychain.set(passcode, account: Self.passcodeAccount)
    }

    func signOut() {
        if !DemoMode.isEnabled { Keychain.remove(account: Self.passcodeAccount) }
        userID = ""
    }
}
