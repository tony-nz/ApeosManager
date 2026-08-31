import SwiftUI

/// Departments and users, backed by the device's SOAP management service
/// (`/ssm/Management/Aaa/{Account,User}`).
struct AccountsView: View {
    @ObservedObject var vm: DeviceViewModel
    var requestSignIn: () -> Void

    @State private var mode = Mode.users
    /// One sheet, one binding. Two `.sheet(item:)` modifiers on the same view are not
    /// reliably honoured by SwiftUI -- only one wins, which produced an editor with no
    /// data in it.
    @State private var editor: EditorTarget?
    /// Deletion removes a staff record from the device and cannot be undone, so it is
    /// always confirmed rather than firing on a single click of a small icon.
    @State private var pendingDelete: DeletionTarget?

    enum DeletionTarget: Identifiable {
        case user(DeviceUser)
        case account(DeptAccount)

        var id: String {
            switch self {
            case .user(let u):    return "u-\(u.userID)"
            case .account(let a): return "a-\(a.accountID)"
            }
        }
        var title: String {
            switch self {
            case .user(let u):
                return u.userName.isEmpty ? "Delete user \(u.userID)?"
                                          : "Delete \(u.userName) (\(u.userID))?"
            case .account(let a):
                return a.name.isEmpty ? "Delete department \(a.accountID)?"
                                      : "Delete \(a.name) (\(a.accountID))?"
            }
        }
        var message: String {
            switch self {
            case .user:
                return "This removes the account from the printer, along with any usage counters held against it. It cannot be undone."
            case .account:
                return "This removes the department from the printer, along with its usage counters. It cannot be undone."
            }
        }
    }

    enum EditorTarget: Identifiable {
        case account(DeptAccount, isNew: Bool)
        case user(DeviceUser, isNew: Bool)
        case usage(DeviceUser)

        var id: String {
            switch self {
            case .account(let a, let isNew): return "acct-\(isNew)-\(a.accountID)"
            case .user(let u, let isNew):    return "user-\(isNew)-\(u.userID)"
            case .usage(let u):              return "usage-\(u.userID)"
            }
        }
    }

    enum Mode: String, CaseIterable { case departments = "Departments", users = "Users" }

    var body: some View {
        if !vm.isSignedIn {
            ContentUnavailableView {
                Label("Administrator Sign-In Required", systemImage: "person.badge.key")
            } description: {
                Text("Department and user records require an administrator session.")
            } actions: {
                Button("Sign In…", action: requestSignIn).buttonStyle(.borderedProminent)
            }
        } else {
            VStack(spacing: 0) {
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                .padding(.horizontal, 20).padding(.bottom, 8)

                if let e = (mode == .users ? vm.usersError : vm.accountsError) {
                    Label(e, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.orange)
                        .padding(.horizontal, 20).padding(.bottom, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Group { mode == .departments ? AnyView(departments) : AnyView(usersTable) }

                HStack {
                    Button {
                        editor = mode == .departments
                            ? .account(DeptAccount(accountID: "", name: "", newUserDefault: false), isNew: true)
                            : .user(DeviceUser(userID: "", userName: "", userType: "CO"), isNew: true)
                    } label: { Label("Add", systemImage: "plus") }

                    Button("Reload") { Task { await vm.loadDirectory() } }
                    if vm.loadingAccounts { ProgressView().controlSize(.small) }
                    Spacer()
                }
                .padding(.horizontal, 20).padding(.vertical, 12)
            }
            .alert(item: $pendingDelete) { target in
                Alert(title: Text(target.title),
                      message: Text(target.message),
                      primaryButton: .destructive(Text("Delete")) {
                          switch target {
                          case .user(let u):    Task { await vm.deleteUser(u) }
                          case .account(let a): Task { await vm.deleteAccount(a) }
                          }
                      },
                      secondaryButton: .cancel())
            }
            .sheet(item: $editor) { target in
                switch target {
                case .account(let acct, let isNew):
                    AccountEditor(account: acct, isNew: isNew) { saved in
                        Task { await vm.saveAccount(saved, isNew: isNew) }
                    }
                case .user(let user, let isNew):
                    UserEditor(user: user, isNew: isNew, existingIDs: Set(vm.users.map(\.userID))) { saved, pw in
                        Task { await vm.saveUser(saved, password: pw, isNew: isNew) }
                    }
                case .usage(let user):
                    UsageEditor(user: user, vm: vm)
                }
            }
        }
    }

    private var departments: some View {
        Group {
            if vm.accounts.isEmpty && !vm.loadingAccounts {
                emptyState("No departments configured",
                           vm.accountingUnavailable
                           ? "The device's accounting service is not running — device accounting is switched off (Accounting/Billing Device Settings → accounting type is NONE). Enable it on the device to create departments."
                           : "Add a department to begin tracking usage.")
            } else {
                Table(vm.accounts) {
                    TableColumn("ID") { Text($0.accountID).monospacedDigit() }
                    TableColumn("Name") { Text($0.name.isEmpty ? "—" : $0.name) }
                    TableColumn("Default for new users") { a in
                        Image(systemName: a.newUserDefault ? "checkmark.circle.fill" : "minus")
                            .foregroundStyle(a.newUserDefault ? .green : .secondary)
                    }
                    TableColumn("Usage") { a in
                        Text(a.usage.isEmpty ? "—"
                             : a.usage.sorted { $0.key < $1.key }
                                      .map { "\($0.key): \($0.value)" }.joined(separator: "  "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    TableColumn("") { a in
                        HStack {
                            Button("Edit") { editor = .account(a, isNew: false) }
                            Button(role: .destructive) { pendingDelete = .account(a) }
                                label: { Image(systemName: "trash") }
                        }
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    private var usersTable: some View {
        Group {
            if vm.users.isEmpty && !vm.loadingAccounts {
                emptyState("No local users",
                           "This device has no local user accounts. Add one, or configure LDAP/Azure AD for network authentication.")
            } else {
                Table(vm.users) {
                    TableColumn("User ID") { Text($0.userID).monospaced() }
                    TableColumn("Name") { Text($0.userName.isEmpty ? "—" : $0.userName) }
                    TableColumn("Type") { u in
                        Text(AaaUserType(rawValue: u.userType)?.label ?? u.userType)
                    }
                    TableColumn("Roles") { u in
                        Text(u.roles.isEmpty ? "—" : u.roles.joined(separator: ", "))
                            .foregroundStyle(.secondary)
                    }
                    TableColumn("Usage") { u in
                        let print = u.usage.filter { $0.feature == "Print" }
                        let copy = u.usage.filter { $0.feature == "Copy" }
                        let total = (print + copy).reduce(0) { $0 + $1.used }
                        Text(u.usage.isEmpty ? "—" : "\(total)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .help("Print + copy impressions recorded against this user")
                    }
                    TableColumn("Departments") { u in
                        Text(u.associates.isEmpty ? "—" : u.associates.joined(separator: ", "))
                            .foregroundStyle(.secondary)
                    }
                    TableColumn("") { u in
                        HStack {
                            Button("Usage") { editor = .usage(u) }
                            Button("Edit") { editor = .user(u, isNew: false) }
                            Button(role: .destructive) { pendingDelete = .user(u) }
                                label: { Image(systemName: "trash") }
                        }
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    private func emptyState(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 420)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Editors

struct AccountEditor: View {
    @State private var draft: DeptAccount
    private let isNew: Bool
    private let onSave: (DeptAccount) -> Void
    @Environment(\.dismiss) private var dismiss

    init(account: DeptAccount, isNew: Bool, onSave: @escaping (DeptAccount) -> Void) {
        _draft = State(initialValue: account)
        self.isNew = isNew
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "New Department" : "Edit Department").font(.title3).bold()
            Form {
                TextField("Account ID", text: $draft.accountID, prompt: Text("e.g. 100"))
                    .disabled(!isNew)
                TextField("Name", text: $draft.name, prompt: Text("Department name"))
                Toggle("Default for new users", isOn: $draft.newUserDefault)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { onSave(draft); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.accountID.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20).frame(width: 420)
    }
}

struct UserEditor: View {
    @State private var draft: DeviceUser
    @State private var password = ""
    private let isNew: Bool
    private let originalID: String
    private let existingIDs: Set<String>
    private let onSave: (DeviceUser, String?) -> Void
    @Environment(\.dismiss) private var dismiss

    /// State is seeded in init rather than via a `@State var` parameter, which SwiftUI
    /// only honours the first time a view is created and otherwise leaves stale.
    init(user: DeviceUser, isNew: Bool, existingIDs: Set<String>,
         onSave: @escaping (DeviceUser, String?) -> Void) {
        _draft = State(initialValue: user)
        self.isNew = isNew
        self.originalID = user.userID
        self.existingIDs = existingIDs
        self.onSave = onSave
    }

    private var trimmedID: String {
        draft.userID.trimmingCharacters(in: .whitespaces)
    }
    private var idIsDuplicate: Bool {
        isNew && existingIDs.contains(trimmedID)
    }
    private var idChanged: Bool { !isNew && trimmedID != originalID }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "New User" : "Edit User").font(.title3).bold()

            Form {
                TextField("User ID", text: $draft.userID,
                          prompt: Text("e.g. 12345"))
                TextField("Display name", text: $draft.userName,
                          prompt: Text("Full name shown on the panel"))
                Picker("Type", selection: $draft.userType) {
                    ForEach(AaaUserType.allCases) { Text($0.label).tag($0.rawValue) }
                }
                SecureField(isNew ? "Password (optional)" : "New password (leave blank to keep)",
                            text: $password)
            }
            .formStyle(.grouped)

            if idIsDuplicate {
                Label("A user with this ID already exists on this device.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
            } else if idChanged {
                // SetUserInformation keys on UserID and the device exposes no rename
                // operation, so a changed ID cannot be saved as an edit.
                Label("The device identifies users by ID and cannot rename one. Cancel and add a new user instead.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    var out = draft
                    out.userID = trimmedID
                    out.userName = draft.userName.trimmingCharacters(in: .whitespaces)
                    onSave(out, password.isEmpty ? nil : password)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedID.isEmpty || idIsDuplicate || idChanged)
            }
        }
        .padding(20).frame(width: 460)
    }
}
