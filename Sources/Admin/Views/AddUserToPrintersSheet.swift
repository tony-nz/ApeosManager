import SwiftUI

/// Creates one user on any number of printers, reporting the outcome per device rather
/// than a single pass/fail -- some devices may refuse while others accept.
///
/// The questions asked, and everything applied after the create, live in `NewUserDraft`
/// and `applyNewUser` so this and the per-printer sheet cannot drift apart. What is
/// particular to this sheet is the Printers tab and the loop over devices.
struct AddUserToPrintersSheet: View {
    @EnvironmentObject var store: PrinterStore
    @EnvironmentObject var fleet: Fleet
    @Environment(\.dismiss) private var dismiss

    @State private var pane: NewUserPane = .details
    @State private var draft = NewUserDraft()
    @State private var targets: Set<UUID> = []
    @State private var running = false
    @State private var results: [UUID: String] = [:]
    @State private var finished = false

    @State private var seeded = false
    @State private var savedDefaults = NewUserDefaultsStore.load()

    @State private var template: UserPermissions?
    @State private var templateSource: String?
    @State private var groups: [AuthorizationGroup] = []
    @State private var loadingTemplate = false

    private var devices: [DeviceViewModel] { fleet.ordered() }

    /// A printer that can describe the permission fields: signed in, and holding at
    /// least one record to read them from.
    private var templateDevice: DeviceViewModel? {
        devices.first { targets.contains($0.printer.id) && $0.isSignedIn && !$0.users.isEmpty }
            ?? devices.first { $0.isSignedIn && !$0.users.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add User to Printers").font(.title2).bold()

            Picker("", selection: $pane) {
                ForEach(NewUserPane.allCases) { p in
                    Label(p.rawValue, systemImage: p.symbol).tag(p)
                }
            }
            .pickerStyle(.segmented).labelsHidden()

            switch pane {
            case .details:  NewUserDetailsPane(draft: $draft)
            case .printers: printersPane
            case .usage:    NewUserUsagePane(draft: $draft)
            case .permissions:
                NewUserPermissionsPane(draft: $draft, template: template,
                                       templateSource: templateSource,
                                       groups: groups, loading: loadingTemplate)
            }

            Spacer(minLength: 0)

            HStack {
                NewUserDefaultsMenu(draft: $draft, saved: $savedDefaults, disabled: running)
                if running { ProgressView().controlSize(.small) }
                Spacer()
                Button(finished ? "Close" : "Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add User") { Task { await run() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.trimmedID.isEmpty || targets.isEmpty || running)
            }
        }
        .padding(20)
        // One height for all four panes, so clicking a tab does not resize the window.
        .frame(width: 580, height: 580, alignment: .topLeading)
        .task(id: templateDevice?.printer.id) { await loadTemplate() }
        .onAppear {
            guard !seeded else { return }
            seeded = true
            draft.apply(savedDefaults)
        }
    }

    private var printersPane: some View {
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
                                    alreadyHas: vm.users.contains { $0.userID == draft.trimmedID },
                                    result: results[vm.printer.id]) {
                        if targets.contains(vm.printer.id) { targets.remove(vm.printer.id) }
                        else { targets.insert(vm.printer.id) }
                    }
                }
            }
        } label: { Label("Printers", systemImage: "printer.dotmatrix") }
    }

    private func loadTemplate() async {
        guard template == nil, !loadingTemplate, let vm = templateDevice,
              let sample = vm.users.first else { return }
        loadingTemplate = true
        defer { loadingTemplate = false }
        groups = await vm.loadAuthorizationGroups()
        if let read = await vm.loadPermissions(for: sample) {
            template = read
            templateSource = vm.printer.name
        }
    }

    private func run() async {
        running = true; results = [:]
        defer { running = false; finished = true }

        // Only a clean sweep closes the sheet. Anything else -- a printer that refused,
        // one already holding the ID, or a create whose follow-up writes failed -- leaves
        // it open, because the per-printer lines are the only report of that.
        var clean = 0
        for vm in devices where targets.contains(vm.printer.id) {
            let note = await applyNewUser(draft, on: vm)
            results[vm.printer.id] = note
            if note.hasPrefix("added"), !note.contains("failed") { clean += 1 }
        }
        if clean == targets.count { dismiss() }
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
                    .foregroundStyle(result.contains("failed") ? Color.orange
                                     : result.hasPrefix("added") ? Color.green
                                     : result.contains("skipped") ? Color.secondary : Color.orange)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 220, alignment: .trailing)
            } else if alreadyHas {
                Text("already has this ID").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// The same sheet for one printer: the Printers tab and the per-device result lines drop
/// away, everything else is identical by construction.
struct AddUserToPrinterSheet: View {
    @ObservedObject var vm: DeviceViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var pane: NewUserPane = .details
    @State private var draft = NewUserDraft()
    @State private var running = false
    @State private var result: String?

    @State private var seeded = false
    @State private var savedDefaults = NewUserDefaultsStore.load()

    @State private var template: UserPermissions?
    @State private var groups: [AuthorizationGroup] = []
    @State private var loadingTemplate = false

    private var panes: [NewUserPane] { [.details, .usage, .permissions] }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("New User").font(.title2).bold()
                Text("on \(vm.printer.name)").font(.callout).foregroundStyle(.secondary)
            }

            Picker("", selection: $pane) {
                ForEach(panes) { p in Label(p.rawValue, systemImage: p.symbol).tag(p) }
            }
            .pickerStyle(.segmented).labelsHidden()

            switch pane {
            case .usage: NewUserUsagePane(draft: $draft)
            case .permissions:
                NewUserPermissionsPane(draft: $draft, template: template,
                                       templateSource: vm.printer.name,
                                       groups: groups, loading: loadingTemplate)
            default: NewUserDetailsPane(draft: $draft)
            }

            Spacer(minLength: 0)

            if let result {
                Text(result)
                    .font(.callout)
                    .foregroundStyle(result.contains("failed") ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                NewUserDefaultsMenu(draft: $draft, saved: $savedDefaults, disabled: running)
                if running { ProgressView().controlSize(.small) }
                Spacer()
                Button(result == nil ? "Cancel" : "Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add User") { Task { await run() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.trimmedID.isEmpty || running)
            }
        }
        .padding(20)
        .frame(width: 580, height: 580, alignment: .topLeading)
        .task { await loadTemplate() }
        .onAppear {
            guard !seeded else { return }
            seeded = true
            draft.apply(savedDefaults)
        }
    }

    private func loadTemplate() async {
        guard template == nil, !loadingTemplate, vm.isSignedIn,
              let sample = vm.users.first else { return }
        loadingTemplate = true
        defer { loadingTemplate = false }
        groups = await vm.loadAuthorizationGroups()
        template = await vm.loadPermissions(for: sample)
    }

    private func run() async {
        running = true
        defer { running = false }
        let note = await applyNewUser(draft, on: vm)
        // A clean create closes; anything else stays open, since this line is the only
        // place the shortfall is reported.
        if note.hasPrefix("added"), !note.contains("failed") { dismiss() } else { result = note }
    }
}
