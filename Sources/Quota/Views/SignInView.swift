import SwiftUI

/// First-run and sign-in screen: which printers to ask, and who to ask as.
///
/// The credentials are checked against a real printer before they are stored, so a
/// mistyped passcode is caught here rather than surfacing later as six printers that
/// all mysteriously refuse.
struct SignInView: View {
    @ObservedObject var settings: QuotaSettings
    var onSignedIn: () -> Void

    @State private var userID: String = ""
    @State private var passcode: String = ""
    @State private var newHost: String = ""
    @State private var newName: String = ""
    @State private var checking = false
    @State private var error: String?

    @State private var discovery = PrinterDiscovery()
    @State private var scanPrefix = ""
    @State private var scanning = false
    @State private var scanProgress = 0.0
    @State private var found: [DiscoveredPrinter] = []
    @State private var scanTask: Task<Void, Never>?
    @State private var scanned = false

    private var knownHosts: Set<String> { Set(settings.printers.map(\.host)) }

    /// Where to sweep, best guess first.
    ///
    /// A printer that has already been added is the strongest hint available: its
    /// siblings are almost always on the same subnet, and that subnet is often not the
    /// one this Mac sits on -- here the Mac is on 10.69.193 while the printers are on
    /// 10.69.192, so offering only the local interfaces would sweep 254 addresses and
    /// find nothing.
    private var suggestedPrefixes: [String] {
        var out: [String] = []
        for host in settings.printers.map(\.host) {
            let parts = host.split(separator: ".")
            guard parts.count == 4 else { continue }
            let prefix = parts.prefix(3).joined(separator: ".")
            if !out.contains(prefix) { out.append(prefix) }
        }
        for prefix in PrinterDiscovery.localPrefixes() where !out.contains(prefix) {
            out.append(prefix)
        }
        return out
    }

    /// A printer typed into the add field but not yet added counts. Requiring the Add
    /// button first left Sign In greyed out with nothing to say why, which reads as the
    /// app being broken rather than as a step being missed.
    private var pendingHost: String? {
        let host = newHost.trimmed
        return host.isEmpty ? nil : host
    }

    private var canSignIn: Bool {
        !userID.trimmed.isEmpty && !passcode.isEmpty && !checking
            && (!settings.printers.isEmpty || pendingHost != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Apeos Quota").font(.title2.weight(.semibold))
                Text("See how much of your printing allowance is left.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            GroupBox("Printers") {
                VStack(alignment: .leading, spacing: 8) {
                    if settings.printers.isEmpty {
                        Text("Add the printers you use. Your quota is added up across all of them.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        ForEach(settings.printers) { p in
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(p.name).font(.callout)
                                    Text(p.host).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button {
                                    settings.printers.removeAll { $0.id == p.id }
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.secondary)
                                .help("Remove this printer")
                            }
                        }
                        Divider()
                    }
                    HStack(spacing: 6) {
                        Text("Find").frame(width: 34, alignment: .leading)
                        TextField("Subnet", text: $scanPrefix, prompt: Text("192.0.2"))
                            .frame(width: 96)
                        Text(".1–254").font(.caption).foregroundStyle(.secondary)
                        if suggestedPrefixes.count > 1 {
                            Menu {
                                ForEach(suggestedPrefixes, id: \.self) { p in
                                    Button(p) { scanPrefix = p }
                                }
                            } label: { Image(systemName: "chevron.down") }
                                .menuStyle(.borderlessButton)
                                .frame(width: 24)
                                .help("Other subnets found on this Mac")
                        }
                        Spacer()
                        if scanning {
                            ProgressView(value: scanProgress).frame(width: 70)
                            Button("Stop") { scanTask?.cancel(); scanning = false }
                        } else {
                            Button("Scan", action: startScan)
                                .disabled(scanPrefix.trimmed.isEmpty)
                        }
                    }
                    .textFieldStyle(.roundedBorder)

                    let newFinds = found.filter { !knownHosts.contains($0.host) }
                    if !newFinds.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(newFinds) { p in
                                HStack {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(p.name).font(.callout)
                                        Text("\(p.host)\(p.subtitle.isEmpty ? "" : " · \(p.subtitle)")")
                                            .font(.caption).foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    Button("Add") {
                                        settings.printers.append(
                                            QuotaPrinter(name: p.name, host: p.host))
                                    }
                                }
                                .padding(.vertical, 3)
                            }
                        }
                        .frame(maxHeight: 120)
                    } else if scanned && !scanning {
                        Text(found.isEmpty
                             ? "No printers found on \(scanPrefix).0/24."
                             : "Every printer found is already added.")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    Divider()

                    HStack(spacing: 6) {
                        TextField("Name (optional)", text: $newName).frame(width: 130)
                        TextField("Address", text: $newHost)
                            .onSubmit(addPrinter)
                        Button("Add", action: addPrinter)
                            .disabled(newHost.trimmed.isEmpty)
                    }
                    .textFieldStyle(.roundedBorder)
                }
                .padding(4)
            }

            GroupBox("Sign in") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("User ID").frame(width: 70, alignment: .leading)
                        TextField("", text: $userID)
                    }
                    HStack {
                        Text("Passcode").frame(width: 70, alignment: .leading)
                        SecureField("", text: $passcode)
                            .onSubmit { if canSignIn { Task { await signIn() } } }
                    }
                }
                .textFieldStyle(.roundedBorder)
                .padding(4)
            }

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                if checking { ProgressView().controlSize(.small) }
                Button("Sign In") { Task { await signIn() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSignIn)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            userID = settings.userID
            if scanPrefix.isEmpty { scanPrefix = suggestedPrefixes.first ?? "" }
        }
        .onDisappear { scanTask?.cancel() }
    }

    private func startScan() {
        found = []; scanProgress = 0; scanning = true; scanned = false
        let d = discovery
        let sweep = scanPrefix.trimmed
        scanTask = Task {
            await d.scan(prefix: sweep) { p in
                Task { @MainActor in scanProgress = p }
            } onFound: { printer in
                Task { @MainActor in
                    if !found.contains(where: { $0.host == printer.host }) {
                        found.append(printer)
                        found.sort { $0.host.localizedStandardCompare($1.host) == .orderedAscending }
                    }
                }
            }
            await MainActor.run { scanning = false; scanned = true }
        }
    }

    private func addPrinter() {
        let host = newHost.trimmed
        guard !host.isEmpty, !settings.printers.contains(where: { $0.host == host }) else { return }
        let name = newName.trimmed.isEmpty ? host : newName.trimmed
        settings.printers.append(QuotaPrinter(name: name, host: host))
        newHost = ""; newName = ""
    }

    /// Accepts as soon as any one printer takes the credentials. A user may legitimately
    /// have no account on some of the printers they have added, so requiring every one
    /// to succeed would lock out perfectly valid sign-ins.
    private func signIn() async {
        // Take whatever is still sitting in the add field, so a user who typed an
        // address and pressed Sign In gets what they plainly meant.
        addPrinter()

        checking = true; error = nil
        defer { checking = false }

        let id = userID.trimmed

        // A demo signs in against the fixture: any of its user IDs is accepted, with
        // any passcode, and nothing is contacted or stored.
        if DemoMode.isEnabled {
            guard DemoFleet.users.contains(where: { $0.userID == id }) else {
                error = "No such user on the demonstration fleet. "
                    + "Try \(DemoFleet.demoUserID)."
                return
            }
            settings.signIn(userID: id, passcode: passcode)
            passcode = ""
            onSignedIn()
            return
        }

        var lastFailure: String?
        for printer in settings.printers {
            do {
                let client = try ApeosClient(host: printer.host)
                try await client.login(userID: id, password: passcode)
                await client.logout()
                settings.signIn(userID: id, passcode: passcode)
                passcode = ""
                onSignedIn()
                return
            } catch ApeosError.loginFailed {
                lastFailure = "That user ID and passcode were refused."
            } catch {
                lastFailure = "Could not reach \(printer.name)."
            }
        }
        error = lastFailure ?? "Could not sign in."
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
