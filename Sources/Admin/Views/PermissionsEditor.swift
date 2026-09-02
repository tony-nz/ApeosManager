import SwiftUI

/// What one user may do at the panel, and the address their scans are sent from.
/// Mirrors the device's own "User Permissions" and Email "From" Address panels.
///
/// Only fields the device reports are shown. Models differ over which exist — a device
/// without a fax has no fax permission, one without a card reader no card login — and
/// the device rejects a write naming an element it does not have, so anything absent
/// here is left alone rather than defaulted.
struct PermissionsEditor: View {
    let user: DeviceUser
    @ObservedObject var vm: DeviceViewModel
    /// Set when hosted as a pane of `UserInspector`, which supplies the heading and the
    /// window metrics for all three panes so they cannot disagree about either.
    var embedded = false
    @Environment(\.dismiss) private var dismiss

    @State private var loading = true
    @State private var saving = false
    @State private var original: UserPermissions?
    @State private var draft = UserPermissions()
    @State private var groups: [AuthorizationGroup] = []
    @State private var email = ""

    private var permissionsChanged: Bool {
        guard let original else { return false }
        return draft.access != original.access
            || draft.login != original.login
            || draft.role != original.role
            || draft.group?.number != original.group?.number
    }
    private var emailChanged: Bool {
        guard let original, original.mailAddress != nil else { return false }
        return email.trimmingCharacters(in: .whitespaces) != (original.mailAddress ?? "")
    }
    private var hasWork: Bool { permissionsChanged || emailChanged }
    /// Granting administrator rights is the one change here that hands someone the keys.
    private var grantsAdministrator: Bool {
        draft.role != original?.role
            && (draft.role == .systemAdministrator || draft.role == .accountAdministrator)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !embedded {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Permissions").font(.title2).bold()
                    Text("\(user.displayName) · \(user.userID) on \(vm.printer.name)")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            if loading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading the user's record…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if let original, !original.isEmpty {
                if !draft.access.isEmpty || draft.login != nil || draft.role != nil || draft.group != nil {
                    GroupBox("User Permissions") { permissionFields }
                }
                if original.mailAddress != nil {
                    GroupBox("Email “From” Address") {
                        VStack(alignment: .leading, spacing: 6) {
                            TextField("Email address", text: $email,
                                      prompt: Text("Not set"))
                                .textFieldStyle(.roundedBorder)
                            Text("Used as the sender when this user scans to email.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            } else {
                Label("This printer reported no permission fields for the user. They are only populated when authentication and internal accounting are switched on at the device.",
                      systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if grantsAdministrator {
                Label("This gives \(user.displayName) administrator rights on \(vm.printer.name).",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let e = vm.usersError {
                Text(e).font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if saving { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save Changes") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!hasWork || saving)
            }
        }
        .padding(embedded ? 0 : 20)
        .frame(width: embedded ? nil : 560)
        .task { await load() }
    }

    @ViewBuilder
    private var permissionFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(PermissionService.allCases) { service in
                if let current = draft.access[service] {
                    LabeledContent(service.label) {
                        Picker("", selection: Binding(
                            get: { current },
                            set: { draft.access[service] = $0 })) {
                            ForEach(FeaturePermission.choices(for: service)) {
                                Text($0.label).tag($0)
                            }
                        }
                        .labelsHidden()
                    }
                }
            }

            if let login = draft.login {
                LabeledContent("Login Options") {
                    Picker("", selection: Binding(get: { login }, set: { draft.login = $0 })) {
                        // A device with no card reader can only permit or refuse the
                        // panel keypad, so the card choices are not offered.
                        ForEach(draft.cardLoginSupported
                                ? LoginPermission.allCases
                                : [.manual, .none]) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                }
            }

            if let role = draft.role {
                LabeledContent("User Role") {
                    Picker("", selection: Binding(get: { role }, set: { draft.role = $0 })) {
                        ForEach(TraditionalRole.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                }
            }

            if let group = draft.group {
                LabeledContent("Permission Group") {
                    if groups.isEmpty {
                        // The group list is a separate endpoint; without it the current
                        // group is still worth showing, but there is nothing to pick from.
                        Text(group.label).foregroundStyle(.secondary)
                    } else {
                        Picker("", selection: Binding(
                            get: { group.number },
                            set: { number in
                                draft.group = groups.first { $0.number == number } ?? group
                            })) {
                            ForEach(groups) { Text($0.label).tag($0.number) }
                        }
                        .labelsHidden()
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func load() async {
        loading = true
        defer { loading = false }
        // Sequential rather than concurrent: these devices hold few sessions at once,
        // and two requests in flight on one buys nothing here.
        groups = await vm.loadAuthorizationGroups()
        guard let permissions = await vm.loadPermissions(for: user) else { return }
        apply(permissions)
    }

    private func apply(_ permissions: UserPermissions) {
        original = permissions
        draft = permissions
        email = permissions.mailAddress ?? ""
    }

    private func save() async {
        saving = true
        defer { saving = false }

        // Captured before the first write: each save re-reads the record and reseeds
        // the fields from it, which would otherwise discard an edit not yet applied.
        let address = email.trimmingCharacters(in: .whitespaces)
        let needsAddress = emailChanged

        // Two writes, as the device itself splits them: a failure in one must not be
        // reported as if the other had applied.
        if permissionsChanged {
            guard let saved = await vm.savePermissions(for: user, draft) else { return }
            apply(saved)
            email = address
            if vm.usersError != nil { return }
        }
        if needsAddress {
            guard let saved = await vm.saveMailAddress(for: user, address) else { return }
            apply(saved)
            if vm.usersError != nil { return }
        }
        dismiss()
    }
}
