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
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([Printer].self, from: data) {
            printers = decoded
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(printers) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    func add(_ p: Printer, password: String?) {
        printers.append(p)
        if let password, !password.isEmpty { Keychain.set(password, account: p.credentialAccount) }
    }

    func remove(_ p: Printer) {
        Keychain.remove(account: p.credentialAccount)
        printers.removeAll { $0.id == p.id }
    }

    func password(for p: Printer) -> String? { Keychain.get(account: p.credentialAccount) }

    /// True when a password exists but this build is not permitted to read it.
    func passwordLocked(for p: Printer) -> Bool {
        if case .denied = Keychain.lookup(account: p.credentialAccount) { return true }
        return false
    }
    func setPassword(_ pw: String, for p: Printer) { Keychain.set(pw, account: p.credentialAccount) }
}
