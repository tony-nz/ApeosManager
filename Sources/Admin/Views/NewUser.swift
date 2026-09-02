import SwiftUI

/// Everything asked about a user being created, independent of how many printers it is
/// destined for.
///
/// The fleet sheet and the per-printer sheet ask exactly the same questions, and asking
/// them from one place is what keeps the two from drifting -- a field added to one and
/// forgotten in the other is how "add a user here" and "add a user there" end up
/// producing differently configured accounts.
struct NewUserDraft {
    var userID = ""
    var userName = ""
    var userType = AaaUserType.customerOperator.rawValue
    var password = ""

    var limits: [String: String] = [:]
    var unlimited: [String: Bool] =
        Dictionary(uniqueKeysWithValues: UsageMeter.allTypes.map { ($0, true) })

    var access: [PermissionService: FeaturePermission] = [:]
    var login: LoginPermission?
    var role: TraditionalRole?
    var group: AuthorizationGroup?
    var mailAddress = ""
    /// Whether the address is also filed as an address book contact, so the user can be
    /// scanned to by name rather than by somebody retyping the address at the panel.
    var addToAddressBook = true

    var trimmedID: String { userID.trimmingCharacters(in: .whitespaces) }
    var trimmedName: String { userName.trimmingCharacters(in: .whitespaces) }
    var wantedMail: String { mailAddress.trimmingCharacters(in: .whitespaces) }
    var wantsContact: Bool { addToAddressBook && !wantedMail.isEmpty }

    var hasPermissionChoices: Bool {
        !access.isEmpty || login != nil || role != nil || group != nil
    }

    /// Meters the operator capped. A cap on one meter is meaningless unless the rest are
    /// explicitly uncapped, so once anything is capped every meter is written; touch
    /// nothing and nothing is written at all.
    var wantedLimits: [String: Int] {
        var out: [String: Int] = [:]
        for type in UsageMeter.allTypes where !(unlimited[type] ?? true) {
            if let v = Int((limits[type] ?? "").trimmingCharacters(in: .whitespaces)) {
                out[type] = max(0, v)
            }
        }
        guard !out.isEmpty else { return [:] }
        for type in UsageMeter.allTypes where out[type] == nil {
            out[type] = UsageMeter.unlimited
        }
        return out
    }

    var asDeviceUser: DeviceUser {
        DeviceUser(userID: trimmedID, userName: trimmedName, userType: userType)
    }

    /// Seeds from saved defaults. A meter at or above the unlimited sentinel shows as
    /// unlimited rather than as the number, which is what the device means by it.
    mutating func apply(_ d: NewUserDefaults) {
        if let type = d.userType { userType = type }
        for type in UsageMeter.allTypes {
            guard let value = d.limits[type] else {
                unlimited[type] = true; limits[type] = ""; continue
            }
            let uncapped = value >= UsageMeter.unlimited
            unlimited[type] = uncapped
            limits[type] = uncapped ? "" : String(value)
        }
        access = d.access.reduce(into: [:]) { out, pair in
            if let service = PermissionService(rawValue: pair.key),
               let value = FeaturePermission(rawValue: pair.value) { out[service] = value }
        }
        login = d.login.flatMap(LoginPermission.init(rawValue:))
        role = d.role.flatMap(TraditionalRole.init(rawValue:))
        group = d.group
    }

    /// The policy worth keeping for next time. The user ID, name, password and address
    /// are deliberately excluded: they identify one person, not a default for the next.
    func captured() -> NewUserDefaults {
        var d = NewUserDefaults()
        d.userType = userType
        for type in UsageMeter.allTypes {
            d.limits[type] = (unlimited[type] ?? true)
                ? UsageMeter.unlimited
                : (Int((limits[type] ?? "").trimmingCharacters(in: .whitespaces)).map { max(0, $0) }
                   ?? UsageMeter.unlimited)
        }
        d.access = access.reduce(into: [:]) { $0[$1.key.rawValue] = $1.value.rawValue }
        d.login = login?.rawValue
        d.role = role?.rawValue
        d.groupNumber = group?.number
        d.groupName = group?.name
        return d
    }
}

// MARK: - Applying a draft to one printer

/// Creates the user on one printer and applies everything else the draft asked for.
///
/// Four separate device writes follow the create, and the first failure stops the rest:
/// writing permissions onto a record whose limits were just rejected would report a
/// success that only half happened. The return value is the line shown against that
/// printer, which is the only place these outcomes are reported.
@MainActor
func applyNewUser(_ draft: NewUserDraft, on vm: DeviceViewModel) async -> String {
    let wanted = draft.asDeviceUser

    if vm.users.contains(where: { $0.userID == wanted.userID }) {
        return "already present — skipped"
    }

    await vm.saveUser(wanted, password: draft.password.isEmpty ? nil : draft.password, isNew: true)
    if let err = vm.usersError { return err }
    guard let created = vm.users.first(where: { $0.userID == wanted.userID }) else {
        return "device reported success but the user is not listed"
    }

    var applied: [String] = []
    var failure: String?

    let limits = draft.wantedLimits
    if !limits.isEmpty {
        await vm.saveUsageLimits(created, limits: limits)
        if let err = vm.usersError { failure = "limits failed: \(err)" }
        else { applied.append("limits") }
    }
    if failure == nil, draft.hasPermissionChoices {
        if await vm.applyChosenPermissions(to: created, draft) { applied.append("permissions") }
        else { failure = "permissions failed: \(vm.usersError ?? "unknown error")" }
    }
    if failure == nil, !draft.wantedMail.isEmpty {
        if await vm.saveMailAddress(for: created, draft.wantedMail) != nil, vm.usersError == nil {
            applied.append("email address")
        } else {
            failure = "email address failed: \(vm.usersError ?? "unknown error")"
        }
    }
    if failure == nil, draft.wantsContact {
        if await vm.addContact(named: created.displayName.isEmpty ? created.userID : created.displayName,
                               email: draft.wantedMail) {
            applied.append("address book")
        } else {
            failure = "address book failed: \(vm.contactsError ?? "unknown error")"
        }
    }

    if let failure { return "added, but \(failure)" }
    return applied.isEmpty ? "added" : "added with \(listed(applied))"
}

private func listed(_ items: [String]) -> String {
    guard items.count > 1, let last = items.last else { return items.joined() }
    return items.dropLast().joined(separator: ", ") + " and " + last
}

// MARK: - Panes

struct NewUserDetailsPane: View {
    @Binding var draft: NewUserDraft

    var body: some View {
        // One grouped Form rather than a Form plus a GroupBox: a grouped Form takes all
        // the height going, which left the email box stranded at the foot of the sheet.
        Form {
            Section {
                TextField("User ID", text: $draft.userID, prompt: Text("e.g. 12345"))
                TextField("Display name", text: $draft.userName, prompt: Text("Full name"))
                Picker("Type", selection: $draft.userType) {
                    ForEach(AaaUserType.allCases) { Text($0.label).tag($0.rawValue) }
                }
                SecureField("Password (optional)", text: $draft.password)
            }

            Section {
                TextField("Email", text: $draft.mailAddress,
                          prompt: Text("name@example.school.nz"))
                Toggle("Also add to the address book", isOn: $draft.addToAddressBook)
                    .disabled(draft.wantedMail.isEmpty)
            } header: {
                Text("Email")
            } footer: {
                Text(draft.wantedMail.isEmpty
                     ? "Sets the sender address used when this user scans to email."
                     : draft.addToAddressBook
                       ? "Sets the sender address for their scans, and files them in the address book so others can scan to them by name."
                       : "Sets the sender address for their scans only.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}

struct NewUserUsagePane: View {
    @Binding var draft: NewUserDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            UsageLimitsFields(limits: $draft.limits, unlimited: $draft.unlimited)
            Text(draft.wantedLimits.isEmpty
                 ? "Every meter is unlimited, so no limits will be written."
                 : "Applied once the account has been created.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// The permission fields, shaped by what a real printer reports.
///
/// Permissions cannot be composed from nothing: which access services a device has, and
/// whether it has a card reader, is only discoverable from a record it already holds.
/// So the fields come from a printer that is signed in, and each defaults to leaving the
/// device's own default alone -- only what is actually changed is written.
struct NewUserPermissionsPane: View {
    @Binding var draft: NewUserDraft
    let template: UserPermissions?
    let templateSource: String?
    let groups: [AuthorizationGroup]
    let loading: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if loading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading the available permissions…").foregroundStyle(.secondary)
                }
            } else if let template, !template.isEmpty {
                if let templateSource {
                    Text("Fields as reported by \(templateSource). Anything left as “Device default” is not written.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                GroupBox { fields(template) }
            } else {
                Label("No signed-in printer could describe its permission fields, so they cannot be set here. Create the user, then set permissions from its Edit sheet.",
                      systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func fields(_ template: UserPermissions) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(PermissionService.allCases) { service in
                if template.access[service] != nil {
                    LabeledContent(service.label) {
                        Picker("", selection: Binding(
                            get: { draft.access[service] },
                            set: { draft.access[service] = $0 })) {
                            Text("Device default").tag(FeaturePermission?.none)
                            ForEach(FeaturePermission.choices(for: service)) {
                                Text($0.label).tag(FeaturePermission?.some($0))
                            }
                        }
                        .labelsHidden()
                    }
                }
            }
            if template.login != nil {
                LabeledContent("Login Options") {
                    Picker("", selection: $draft.login) {
                        Text("Device default").tag(LoginPermission?.none)
                        ForEach(template.cardLoginSupported
                                ? LoginPermission.allCases
                                : [.manual, .none]) { Text($0.label).tag(LoginPermission?.some($0)) }
                    }
                    .labelsHidden()
                }
            }
            if template.role != nil {
                LabeledContent("User Role") {
                    Picker("", selection: $draft.role) {
                        Text("Device default").tag(TraditionalRole?.none)
                        ForEach(TraditionalRole.allCases) { Text($0.label).tag(TraditionalRole?.some($0)) }
                    }
                    .labelsHidden()
                }
            }
            if template.group != nil, !groups.isEmpty {
                LabeledContent("Permission Group") {
                    Picker("", selection: Binding(
                        get: { draft.group?.number },
                        set: { n in draft.group = n.flatMap { num in groups.first { $0.number == num } } })) {
                        Text("Device default").tag(Int?.none)
                        ForEach(groups) { Text($0.label).tag(Int?.some($0.number)) }
                    }
                    .labelsHidden()
                }
            }
            if draft.role == .systemAdministrator || draft.role == .accountAdministrator {
                Label("This grants administrator rights.", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }
}

struct NewUserDefaultsMenu: View {
    @Binding var draft: NewUserDraft
    @Binding var saved: NewUserDefaults
    var disabled: Bool

    var body: some View {
        Menu("Defaults") {
            Button("Save These as Defaults") {
                let d = draft.captured()
                NewUserDefaultsStore.save(d)
                saved = d
            }
            Button("Restore Saved Defaults") { draft.apply(saved) }
                .disabled(saved.isEmpty)
            Divider()
            Button("Clear Saved Defaults") {
                NewUserDefaultsStore.clear()
                saved = NewUserDefaults()
            }
            .disabled(saved.isEmpty)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(disabled)
    }
}

/// The four panes both sheets show, minus the fleet-only Printers tab.
enum NewUserPane: String, CaseIterable, Identifiable {
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
