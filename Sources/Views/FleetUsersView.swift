import SwiftUI

/// Every user across the fleet, with the printers each one exists on and the roles the
/// device grants them. The union is keyed by user ID, which is what the devices key on.
struct FleetUsersView: View {
    @EnvironmentObject var store: PrinterStore
    @EnvironmentObject var fleet: Fleet

    @State private var search = ""
    @State private var showAdd = false
    @State private var editing: FleetUser?
    @State private var selected: FleetUser.ID?
    @State private var onlyIncomplete = false

    private var devices: [DeviceViewModel] { fleet.ordered() }

    /// Signed-in printers only: a printer we could not read has no opinion about who
    /// exists, and must not be shown as "user missing".
    private var readable: [DeviceViewModel] {
        devices.filter { $0.isSignedIn || !$0.users.isEmpty }
    }

    private var users: [FleetUser] {
        var merged: [String: FleetUser] = [:]
        for vm in readable {
            for u in vm.users {
                var entry = merged[u.userID] ?? FleetUser(userID: u.userID, name: u.userName,
                                                          type: u.userType, roles: u.roles,
                                                          presentOn: [])
                if entry.name.isEmpty { entry.name = u.userName }
                entry.roles = Array(Set(entry.roles).union(u.roles)).sorted()
                entry.presentOn.insert(vm.printer.id)
                merged[u.userID] = entry
            }
        }
        var list = Array(merged.values)
        if onlyIncomplete {
            list = list.filter { $0.presentOn.count < readable.count }
        }
        if !search.isEmpty {
            let q = search.lowercased()
            list = list.filter { $0.userID.lowercased().contains(q) || $0.name.lowercased().contains(q) }
        }
        return list.sorted { $0.userID.localizedStandardCompare($1.userID) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Users").font(.title2).bold()
                if fleet.isLoadingAll { ProgressView().controlSize(.small) }
                Spacer()
                Toggle("Missing from some printers", isOn: $onlyIncomplete)
                    .toggleStyle(.checkbox)
                Button {
                    if let id = selected, let u = users.first(where: { $0.id == id }) { editing = u }
                } label: { Label("Edit", systemImage: "pencil") }
                .disabled(selected == nil)
                Button { showAdd = true } label: { Label("Add User", systemImage: "person.badge.plus") }
                Button { Task { await fleet.refreshAll() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 8)

            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search by ID or name", text: $search)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 20).padding(.bottom, 10)

            if readable.isEmpty {
                ContentUnavailableView("No printers readable",
                                       systemImage: "person.badge.key",
                                       description: Text("Printers need an administrator sign-in before their users can be listed."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(users, selection: $selected) {
                    TableColumn("User ID") { Text($0.userID).monospaced() }
                    TableColumn("Name") { Text($0.name.isEmpty ? "—" : $0.name) }
                    TableColumn("Type") { u in
                        Text(AaaUserType(rawValue: u.type)?.label ?? u.type)
                    }
                    TableColumn("Roles") { u in
                        Text(u.roles.isEmpty ? "—" : u.roles.joined(separator: ", "))
                            .foregroundStyle(.secondary)
                    }
                    TableColumn("On") { u in
                        Text("\(u.presentOn.count)/\(readable.count)")
                            .monospacedDigit()
                            .foregroundStyle(u.presentOn.count == readable.count ? Color.secondary : Color.orange)
                    }
                    TableColumn("Printers") { u in
                        HStack(spacing: 4) {
                            ForEach(readable, id: \.printer.id) { vm in
                                Image(systemName: u.presentOn.contains(vm.printer.id)
                                      ? "checkmark.circle.fill" : "circle.dotted")
                                    .foregroundStyle(u.presentOn.contains(vm.printer.id)
                                                     ? Color.green : Color.secondary.opacity(0.5))
                                    .help(vm.printer.name)
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .contextMenu(forSelectionType: FleetUser.ID.self) { ids in
                    if let id = ids.first, let u = users.first(where: { $0.id == id }) {
                        Button("Edit…") { editing = u }
                    }
                } primaryAction: { ids in
                    if let id = ids.first, let u = users.first(where: { $0.id == id }) { editing = u }
                }
            }

            // With nothing readable the legend would name no columns; the empty state
            // already explains why.
            if !readable.isEmpty {
                HStack {
                    Text(legend).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 20).padding(.vertical, 10)
            }
        }
        .sheet(isPresented: $showAdd) { AddUserToPrintersSheet() }
        .sheet(item: $editing) { FleetUserEditor(user: $0) }
        .task { await fleet.connectAll() }
    }

    private var legend: String {
        let names = readable.map(\.printer.name).joined(separator: " · ")
        let skipped = devices.count - readable.count
        return skipped > 0
            ? "Printer columns, in order: \(names). \(skipped) printer(s) not readable and excluded."
            : "Printer columns, in order: \(names)"
    }
}
