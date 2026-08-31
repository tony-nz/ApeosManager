import SwiftUI

/// Edits one user across the fleet: details, and which printers hold the account.
///
/// Ticking a printer creates the account there; unticking removes it. Removal deletes
/// the record and its usage counters on that device, so it is confirmed separately and
/// never applied as a side effect of saving a name change.
struct FleetUserEditor: View {
    let original: FleetUser
    @EnvironmentObject var fleet: Fleet
    @Environment(\.dismiss) private var dismiss

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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit \(original.userID)").font(.title2).bold()

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

            if !removals.isEmpty {
                Label("Unticking removes the account and its usage counters from " +
                      removals.map(\.printer.name).joined(separator: ", ") + ".",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

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
        .padding(20)
        .frame(width: 580)
        .alert("Remove \(original.userID) from \(removals.count) printer(s)?",
               isPresented: $confirmRemovals) {
            Button("Remove", role: .destructive) { Task { await apply() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes the account and its usage counters on \(removals.map(\.printer.name).joined(separator: ", ")). It cannot be undone.")
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
