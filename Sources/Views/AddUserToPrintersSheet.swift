import SwiftUI

/// Creates one user on any number of printers, reporting the outcome per device rather
/// than a single pass/fail -- some devices may refuse while others accept.
struct AddUserToPrintersSheet: View {
    @EnvironmentObject var store: PrinterStore
    @EnvironmentObject var fleet: Fleet
    @Environment(\.dismiss) private var dismiss

    @State private var userID = ""
    @State private var userName = ""
    @State private var userType = AaaUserType.customerOperator.rawValue
    @State private var password = ""
    @State private var targets: Set<UUID> = []
    @State private var running = false
    @State private var results: [UUID: String] = [:]
    @State private var finished = false

    private var devices: [DeviceViewModel] { fleet.ordered() }
    private var trimmedID: String { userID.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add User to Printers").font(.title2).bold()

            Form {
                TextField("User ID", text: $userID, prompt: Text("e.g. 12345"))
                TextField("Display name", text: $userName, prompt: Text("Full name"))
                Picker("Type", selection: $userType) {
                    ForEach(AaaUserType.allCases) { Text($0.label).tag($0.rawValue) }
                }
                SecureField("Password (optional)", text: $password)
            }
            .formStyle(.grouped)

            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Button("Select All") { targets = Set(devices.map(\.printer.id)) }
                        Button("None") { targets = [] }
                        Spacer()
                        Text("\(targets.count) selected").font(.caption).foregroundStyle(.secondary)
                    }
                    Divider()
                    ForEach(devices, id: \.printer.id) { vm in
                        PrinterCheckRow(vm: vm,
                                        isOn: targets.contains(vm.printer.id),
                                        alreadyHas: vm.users.contains { $0.userID == trimmedID },
                                        result: results[vm.printer.id]) {
                            if targets.contains(vm.printer.id) { targets.remove(vm.printer.id) }
                            else { targets.insert(vm.printer.id) }
                        }
                    }
                }
            } label: { Label("Printers", systemImage: "printer.dotmatrix") }

            HStack {
                if running { ProgressView().controlSize(.small) }
                Spacer()
                Button(finished ? "Close" : "Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add User") { Task { await run() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedID.isEmpty || targets.isEmpty || running)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func run() async {
        running = true; results = [:]
        defer { running = false; finished = true }

        let draft = DeviceUser(userID: trimmedID,
                               userName: userName.trimmingCharacters(in: .whitespaces),
                               userType: userType)
        for vm in devices where targets.contains(vm.printer.id) {
            if vm.users.contains(where: { $0.userID == draft.userID }) {
                results[vm.printer.id] = "already present — skipped"
                continue
            }
            await vm.saveUser(draft, password: password.isEmpty ? nil : password, isNew: true)
            // saveUser re-reads and reports mismatches, so trust its verdict.
            if let err = vm.usersError {
                results[vm.printer.id] = err
            } else if vm.users.contains(where: { $0.userID == draft.userID }) {
                results[vm.printer.id] = "added"
            } else {
                results[vm.printer.id] = "device reported success but the user is not listed"
            }
        }
    }
}

private struct PrinterCheckRow: View {
    @ObservedObject var vm: DeviceViewModel
    let isOn: Bool
    let alreadyHas: Bool
    let result: String?
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Toggle(isOn: Binding(get: { isOn }, set: { _ in toggle() })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(vm.printer.name)
                    Text(vm.isSignedIn ? vm.printer.host : "\(vm.printer.host) · not signed in")
                        .font(.caption)
                        .foregroundStyle(vm.isSignedIn ? Color.secondary : Color.orange)
                }
            }
            .toggleStyle(.checkbox)
            Spacer()
            if let result {
                Text(result)
                    .font(.caption)
                    .foregroundStyle(result == "added" ? Color.green
                                     : result.contains("skipped") ? Color.secondary : Color.orange)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 220, alignment: .trailing)
            } else if alreadyHas {
                Text("already has this ID").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
