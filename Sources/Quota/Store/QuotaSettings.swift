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
    @Published var userID: String = "" { didSet { defaults.set(userID, forKey: Key.userID) } }
    /// Minutes between automatic refreshes. Meters move slowly and every refresh costs
    /// the device a sign-in, so the default is deliberately unhurried.
    @Published var refreshMinutes: Int = 15 { didSet { defaults.set(refreshMinutes, forKey: Key.refresh) } }

    private let defaults = UserDefaults.standard
    private enum Key {
        static let printers = "quota.printers.v1"
        static let userID   = "quota.userID"
        static let refresh  = "quota.refreshMinutes"
    }
    /// One account key, not one per user: signing in as somebody else replaces the
    /// stored passcode rather than leaving the previous user's behind.
    private static let passcodeAccount = "signed-in-user"

    init() {
        if let data = defaults.data(forKey: Key.printers),
           let decoded = try? JSONDecoder().decode([QuotaPrinter].self, from: data) {
            printers = decoded
        }
        userID = defaults.string(forKey: Key.userID) ?? ""
        let stored = defaults.integer(forKey: Key.refresh)
        refreshMinutes = stored > 0 ? stored : 15
    }

    private func savePrinters() {
        guard let data = try? JSONEncoder().encode(printers) else { return }
        defaults.set(data, forKey: Key.printers)
    }

    // MARK: - Credentials

    var passcode: String? { Keychain.get(account: Self.passcodeAccount) }

    /// True when a passcode is stored but this build cannot read it, which happens
    /// whenever the app's code signature changes. Worth distinguishing from "not signed
    /// in", because the remedy is different: sign in again rather than wonder why.
    var passcodeLocked: Bool {
        if case .denied = Keychain.lookup(account: Self.passcodeAccount) { return true }
        return false
    }

    var isSignedIn: Bool { !userID.isEmpty && passcode != nil }

    func signIn(userID: String, passcode: String) {
        self.userID = userID
        Keychain.set(passcode, account: Self.passcodeAccount)
    }

    func signOut() {
        Keychain.remove(account: Self.passcodeAccount)
        userID = ""
    }
}
