import SwiftUI

struct AddPrinterSheet: View {
    @EnvironmentObject var store: PrinterStore
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var host = ""
    @State private var adminUser = "11111"
    @State private var password = ""
    @State private var probing = false
    @State private var probeResult: String?

    // Discovery
    @State private var discovery = PrinterDiscovery()
    @State private var scanning = false
    @State private var progress = 0.0
    @State private var found: [DiscoveredPrinter] = []
    @State private var prefix = ""
    @State private var scanTask: Task<Void, Never>?

    private var knownHosts: Set<String> { Set(store.printers.map(\.host)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Printer").font(.title2).bold()

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Scan").frame(width: 52, alignment: .leading)
                        TextField("Subnet", text: $prefix, prompt: Text("192.0.2"))
                            .frame(width: 130)
                        Text(".1–254").foregroundStyle(.secondary).font(.caption)
                        Spacer()
                        if scanning {
                            ProgressView(value: progress).frame(width: 90)
                            Button("Stop") { scanTask?.cancel(); scanning = false }
                        } else {
                            Button("Scan Network") { startScan() }
                                .disabled(prefix.isEmpty)
                        }
                    }

                    if !found.isEmpty {
                        Divider()
                        ScrollView {
                            VStack(spacing: 0) {
                                ForEach(found) { printer in
                                    DiscoveryRow(printer: printer,
                                                 isSelected: host == printer.host,
                                                 alreadyAdded: knownHosts.contains(printer.host)) {
                                        host = printer.host
                                        name = printer.name
                                    }
                                }
                            }
                        }
                        .frame(maxHeight: 150)
                    } else if scanning {
                        Text("Looking for Apeos devices on \(prefix).1–254…")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if progress >= 1.0 {
                        Text("No devices found on \(prefix).0/24.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } label: { Label("Discover", systemImage: "antenna.radiowaves.left.and.right") }

            Form {
                TextField("Name", text: $name, prompt: Text("Staff Room C6570"))
                TextField("Host or IP", text: $host, prompt: Text("192.0.2.10"))
                TextField("Admin user ID", text: $adminUser)
                SecureField("Admin password", text: $password)
            }
            .formStyle(.grouped)

            if let probeResult {
                Text(probeResult).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Test Connection") { Task { await probe() } }
                    .disabled(host.isEmpty || probing)
                if probing { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { scanTask?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") {
                    scanTask?.cancel()
                    let p = Printer(name: name.isEmpty ? host : name,
                                    host: host.trimmingCharacters(in: .whitespaces),
                                    adminUser: adminUser)
                    store.add(p, password: password)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(host.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 540)
        .onAppear { if prefix.isEmpty { prefix = defaultPrefix() } }
        .onDisappear { scanTask?.cancel() }
    }

    /// Printers are commonly on a different subnet from the Mac (here the host sits on
    /// a different subnet from the printers), so an already-added printer is a
    /// better hint than the local interface. Fall back to the interface otherwise.
    private func defaultPrefix() -> String {
        if let existing = store.printers.first?.host {
            let octets = existing.split(separator: ".")
            if octets.count == 4 { return octets.prefix(3).joined(separator: ".") }
        }
        return PrinterDiscovery.localPrefix() ?? ""
    }

    private func startScan() {
        found = []; progress = 0; scanning = true
        let d = discovery
        let sweep = prefix.trimmingCharacters(in: .whitespaces)
        scanTask = Task {
            await d.scan(prefix: sweep) { p in
                Task { @MainActor in progress = p }
            } onFound: { printer in
                Task { @MainActor in
                    if !found.contains(where: { $0.host == printer.host }) {
                        found.append(printer)
                        found.sort { lhs, rhs in
                            let l = lhs.host.split(separator: ".").last.flatMap { Int($0) } ?? 0
                            let r = rhs.host.split(separator: ".").last.flatMap { Int($0) } ?? 0
                            return l < r
                        }
                    }
                }
            }
            await MainActor.run { scanning = false }
        }
    }

    private func probe() async {
        probing = true; defer { probing = false }
        let trimmed = host.trimmingCharacters(in: .whitespaces)

        // A demo answers from the fixture. Nothing on this network is contacted.
        if DemoMode.isEnabled {
            guard let demo = DemoFleet.printer(host: trimmed) else {
                probeResult = "No demonstration printer at that address. "
                    + "Try \(DemoFleet.printers[0].host)."
                return
            }
            if name.isEmpty { name = demo.name }
            probeResult = "Found \(demo.name) — serial \(demo.serial), "
                + "firmware \(demo.firmware)."
            return
        }

        let client: ApeosClient
        do { client = try ApeosClient(host: trimmed) }
        catch { probeResult = error.localizedDescription; return }

        do {
            let about = try await client.about()
            if name.isEmpty { name = about.devFrndlName }
            probeResult = "Found \(about.devFrndlName) — serial \(about.serialNumber), firmware \(about.softwareVersion)."
            return
        } catch ApeosError.notAuthenticated {
            // Some models serve /home/api only to an authenticated administrator.
            if !password.isEmpty {
                do {
                    try await client.login(userID: adminUser, password: password)
                    let about = try await client.about()
                    if name.isEmpty { name = about.devFrndlName }
                    probeResult = "Signed in. Found \(about.devFrndlName) — serial \(about.serialNumber), firmware \(about.softwareVersion)."
                } catch {
                    probeResult = "Reachable, but sign-in failed: \(error.localizedDescription)"
                }
            } else {
                let reachable = (try? await client.status()) != nil
                probeResult = reachable
                    ? "Reachable, but this device requires an administrator password to read its details. Enter one above and test again."
                    : "Device refused the request and did not respond to a status check."
            }
            return
        } catch {
            probeResult = "Could not reach device: \(error.localizedDescription)"
            return
        }
    }
}


private struct DiscoveryRow: View {
    let printer: DiscoveredPrinter
    let isSelected: Bool
    let alreadyAdded: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 10) {
                Image(systemName: "printer")
                    .foregroundStyle(alreadyAdded ? Color.secondary : Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(printer.name).fontWeight(isSelected ? .semibold : .regular)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if alreadyAdded {
                    Text("Added").font(.caption).foregroundStyle(.secondary)
                } else if isSelected {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
            .padding(.vertical, 5).padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(alreadyAdded)
    }

    private var subtitle: String {
        printer.subtitle.isEmpty ? printer.host : "\(printer.host) · \(printer.subtitle)"
    }
}
