import SwiftUI

/// Edits one user across the fleet: details, which printers hold the account, and the
/// per-device meters and permissions.
///
/// Ticking a printer creates the account there; unticking removes it. Removal deletes
/// the record and its usage counters on that device, so it is confirmed separately and
/// never applied as a side effect of saving a name change.
///
/// Details and Printers share one footer because they are one operation -- `apply()`
/// adds, updates and removes in a single pass, and splitting the button would make
/// "save the name" and "save the membership" two trips over the same records. Usage and
/// Permissions are per-device and keep the footers of the editors they host.
struct FleetUserEditor: View {
    let original: FleetUser
    @EnvironmentObject var fleet: Fleet
    @Environment(\.dismiss) private var dismiss

    @State private var pane: Pane = .details
    /// Which device's meters and permissions are on show. Nil until the user picks one,
    /// which `selectedDevice` reads as "the first printer holding the account".
    @State private var meterPrinter: UUID?

    enum Pane: String, CaseIterable, Identifiable {
        case details = "Details"
        case printers = "Printers"
        case usage = "Usage"
        case permissions = "Permissions"

        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .details:     return "person.text.rectangle"
            case .printers:    return "printer.dotmatrix"
            case .usage:       return "chart.bar"
            case .permissions: return "lock.shield"
            }
        }
    }

    @State private var name: String
    @State private var type: String
    @State private var password = ""
    @State private var membership: Set<UUID>
    @State private var running = false
    @State private var finished = false
    @State private var confirmRemovals = false
    @State private var results: [UUID: String] = [:]

    init(user: FleetUser) {
        self.original = user
        _name = State(initialValue: user.name)
        _type = State(initialValue: user.type)
        _membership = State(initialValue: user.presentOn)
    }

    private var devices: [DeviceViewModel] { fleet.ordered() }
    private var readable: [DeviceViewModel] { devices.filter { $0.isSignedIn || !$0.users.isEmpty } }
    private var additions: [DeviceViewModel] {
        readable.filter { membership.contains($0.printer.id) && !original.presentOn.contains($0.printer.id) }
    }
    private var removals: [DeviceViewModel] {
        readable.filter { !membership.contains($0.printer.id) && original.presentOn.contains($0.printer.id) }
    }
    private var detailsChanged: Bool {
        name != original.name || type != original.type || !password.isEmpty
    }
    private var hasWork: Bool { detailsChanged || !additions.isEmpty || !removals.isEmpty }
    /// Unticking the last printer is not "remove from two printers", it is "this account
    /// stops existing anywhere". Worth saying plainly, because nothing else says it.
    private var removingEverywhere: Bool { membership.isEmpty && !removals.isEmpty }

    /// Printers that actually hold the account. The meters and permissions of a printer
    /// the user is not on do not exist, so those are never offered.
    private var holders: [DeviceViewModel] {
        readable.filter { original.presentOn.contains($0.printer.id) }
    }
    private var selectedDevice: DeviceViewModel? {
        holders.first { $0.printer.id == meterPrinter } ?? holders.first
    }
    private func deviceUser(on vm: DeviceViewModel) -> DeviceUser? {
        vm.users.first { $0.userID == original.userID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(original.name.isEmpty ? original.userID : original.name)
                    .font(.title2).bold()
                Text("\(original.userID) · on \(original.presentOn.count) of \(readable.count) printers")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Picker("", selection: $pane) {
                ForEach(Pane.allCases) { p in
                    Label(p.rawValue, systemImage: p.symbol).tag(p)
                }
            }
            .pickerStyle(.segmented).labelsHidden()

            switch pane {
            case .details:     detailsPane
            case .printers:    printersPane
            case .usage:       perDevicePane { UsageEditor(user: $0, vm: $1, embedded: true) }
            case .permissions: perDevicePane { PermissionsEditor(user: $0, vm: $1, embedded: true) }
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        // One height for all four panes: they differ enough in content that letting the
        // sheet size itself would resize the window on every tab click.
        .frame(width: 580, height: 560, alignment: .topLeading)
        .alert(removingEverywhere
               ? "Remove \(original.userID) from every printer?"
               : "Remove \(original.userID) from \(removals.count) printer(s)?",
               isPresented: $confirmRemovals) {
            Button(removingEverywhere ? "Remove Everywhere" : "Remove",
                   role: .destructive) { Task { await apply() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(removingEverywhere
                 ? "This deletes the account, its usage counters and its address book entry from \(removals.map(\.printer.name).joined(separator: ", ")), leaving it on none of them. It cannot be undone."
                 : "This deletes the account and its usage counters on \(removals.map(\.printer.name).joined(separator: ", ")). It cannot be undone.")
        }
    }

    private var detailsPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            Form {
                LabeledContent("User ID") {
                    Text(original.userID).monospaced()
                }
                TextField("Display name", text: $name)
                Picker("Type", selection: $type) {
                    ForEach(AaaUserType.allCases) { Text($0.label).tag($0.rawValue) }
                }
                SecureField("New password (leave blank to keep)", text: $password)
            }
            .formStyle(.grouped)

            Text("Details are written to every printer holding this account.")
                .font(.caption).foregroundStyle(.secondary)

            applyFooter
        }
    }

    private var printersPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Button("All") { membership = Set(readable.map(\.printer.id)) }
                        Button("None") { membership = [] }
                        Spacer()
                        Text("\(membership.count) of \(readable.count)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Divider()
                    ForEach(readable, id: \.printer.id) { vm in
                        MembershipRow(vm: vm,
                                      isOn: membership.contains(vm.printer.id),
                                      was: original.presentOn.contains(vm.printer.id),
                                      result: results[vm.printer.id]) {
                            if membership.contains(vm.printer.id) { membership.remove(vm.printer.id) }
                            else { membership.insert(vm.printer.id) }
                        }
                    }
                }
            } label: { Label("Printers", systemImage: "printer.dotmatrix") }

            if removingEverywhere {
                Label("This will delete \(original.userID) from every printer, along with its usage counters and address book entry. The account will no longer exist anywhere in the fleet.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !removals.isEmpty {
                Label("Unticking removes the account and its usage counters from " +
                      removals.map(\.printer.name).joined(separator: ", ") + ".",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            applyFooter
        }
    }

    /// Usage and Permissions belong to one device, so both panes are the same frame: a
    /// printer to read them from, and that device's own editor beneath it.
    private func perDevicePane<Content: View>(
        @ViewBuilder _ editor: @escaping (DeviceUser, DeviceViewModel) -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if holders.isEmpty {
                Label("This account is not on any readable printer, so it has no meters or permissions to show.",
                      systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Picker("Printer", selection: Binding(
                    get: { selectedDevice?.printer.id },
                    set: { meterPrinter = $0 })) {
                    ForEach(holders, id: \.printer.id) { vm in
                        Text(vm.printer.name).tag(Optional(vm.printer.id))
                    }
                }
                .fixedSize()

                Divider()

                if let vm = selectedDevice {
                    if let du = deviceUser(on: vm) {
                        // Both editors seed @State from the user in init, which SwiftUI
                        // honours only once per view identity. Without an id tied to the
                        // device, changing the picker would leave the previous printer's
                        // limits and permissions on screen against the new printer's name.
                        editor(du, vm).id(vm.printer.id)
                    } else {
                        // Present in the merged fleet list but absent from this device's
                        // loaded records -- it has not been read since sign-in.
                        Label("\(vm.printer.name) has not reported this user's record yet. Reload the printer and try again.",
                              systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var applyFooter: some View {
        HStack {
            if running { ProgressView().controlSize(.small) }
            Spacer()
            Button(finished ? "Close" : "Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Save Changes") {
                if removals.isEmpty { Task { await apply() } } else { confirmRemovals = true }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!hasWork || running)
        }
    }

    private func apply() async {
        running = true; results = [:]
        defer { running = false; finished = true }

        let draft = DeviceUser(userID: original.userID,
                               userName: name.trimmingCharacters(in: .whitespaces),
                               userType: type)

        for vm in additions {
            await vm.saveUser(draft, password: password.isEmpty ? nil : password, isNew: true)
            results[vm.printer.id] = vm.usersError ?? "added"
        }
        if detailsChanged {
            for vm in readable where membership.contains(vm.printer.id)
                && original.presentOn.contains(vm.printer.id) {
                await vm.saveUser(draft, password: password.isEmpty ? nil : password, isNew: false)
                results[vm.printer.id] = vm.usersError ?? "updated"
            }
        }
        for vm in removals {
            if let existing = vm.users.first(where: { $0.userID == original.userID }) {
                await vm.deleteUser(existing)
                results[vm.printer.id] = vm.usersError ?? "removed"
            }
        }
    }
}

private struct MembershipRow: View {
    @ObservedObject var vm: DeviceViewModel
    let isOn: Bool
    let was: Bool
    let result: String?
    let toggle: () -> Void

    private var change: String? {
        if isOn && !was { return "will be added" }
        if !isOn && was { return "will be removed" }
        return nil
    }

    var body: some View {
        HStack(spacing: 8) {
            Toggle(isOn: Binding(get: { isOn }, set: { _ in toggle() })) {
                Text(vm.printer.name)
            }
            .toggleStyle(.checkbox)
            Spacer()
            if let result {
                Text(result).font(.caption)
                    .foregroundStyle(["added", "updated", "removed"].contains(result)
                                     ? Color.green : Color.orange)
                    .frame(maxWidth: 240, alignment: .trailing)
            } else if let change {
                Text(change).font(.caption)
                    .foregroundStyle(change.contains("removed") ? Color.orange : Color.secondary)
            }
        }
    }
}
