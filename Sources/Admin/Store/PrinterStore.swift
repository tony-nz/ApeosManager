import Foundation

struct Printer: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    var host: String
    var adminUser: String = "11111"

    /// Keychain account key — stable across renames because it is derived from `id`.
    var credentialAccount: String { "printer-\(id.uuidString)" }
}

@MainActor
final class PrinterStore: ObservableObject {
    @Published var printers: [Printer] = [] { didSet { save() } }

    private let key = "printers.v1"

    init() {
        // A demo run shows the fixture and never reads the real list. Substituting the
        // contents rather than loading them is what keeps a demo off the network: these
        // printers have documentation addresses and no keychain items behind them.
        if DemoMode.isEnabled {
            printers = DemoFleet.printers.map {
                Printer(id: $0.id, name: $0.name, host: $0.host, adminUser: DemoFleet.adminUser)
            }
            return
        }
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([Printer].self, from: data) {
            printers = decoded
        }
    }

    private func save() {
        // Adding or removing a printer in a demo must not rewrite the real fleet.
        // `printers` saves on change, so without this, merely opening the app under the
        // flag would replace whatever the operator had configured.
        guard !DemoMode.isEnabled else { return }
        guard let data = try? JSONEncoder().encode(printers) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    /// Returns false when the printer was added but its password could not be saved.
    @discardableResult
    func add(_ p: Printer, password: String?) -> Bool {
        printers.append(p)
        guard !DemoMode.isEnabled, let password, !password.isEmpty else { return true }
        return Keychain.set(password, account: p.credentialAccount)
    }

    func remove(_ p: Printer) {
        if !DemoMode.isEnabled { Keychain.remove(account: p.credentialAccount) }
        printers.removeAll { $0.id == p.id }
    }

    /// The keychain is not consulted in a demo. It is keyed by printer id, so the
    /// fixture's own ids would miss -- but a lookup that happened to hit would hand a
    /// real administrator password to code that has no business holding one.
    ///
    /// One call answers both "what is it" and "is it locked". Asking those separately
    /// read the item twice, and so could raise two keychain prompts per printer.
    func savedPassword(for p: Printer) -> Keychain.Lookup {
        DemoMode.isEnabled ? .notFound : Keychain.lookup(account: p.credentialAccount)
    }

    /// Returns false when the keychain refused to store the password.
    func setPassword(_ pw: String, for p: Printer) -> Bool {
        guard !DemoMode.isEnabled else { return true }
        return Keychain.set(pw, account: p.credentialAccount)
    }
}
