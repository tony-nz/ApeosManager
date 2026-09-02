import SwiftUI

/// The address book on one printer.
struct AddressBookView: View {
    @ObservedObject var vm: DeviceViewModel
    @State private var search = ""
    @State private var favouritesOnly = false
    @State private var editing: Contact?
    @State private var pendingDelete: Contact?
    @State private var selected: Contact.ID?

    private var contacts: [Contact] {
        var list = vm.contacts
        if favouritesOnly { list = list.filter(\.favorite) }
        if !search.isEmpty {
            let q = search.lowercased()
            list = list.filter {
                $0.name.lowercased().contains(q) || $0.company.lowercased().contains(q)
                    || $0.summary.lowercased().contains(q)
            }
        }
        return list
    }

    /// Resolved against the loaded list rather than held alongside the selection, so a
    /// contact deleted or reloaded away cannot open a stale copy of itself.
    private var selectedContact: Contact? {
        selected.flatMap { id in contacts.first { $0.id == id } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search name, company or address", text: $search)
                    .textFieldStyle(.plain)
                Toggle("Favourites only", isOn: $favouritesOnly).toggleStyle(.checkbox)
                Button {
                    if let c = selectedContact { editing = c }
                } label: { Label("Edit", systemImage: "square.and.pencil") }
                .disabled(selectedContact == nil || !vm.isSignedIn)
                Button(role: .destructive) {
                    if let c = selectedContact { pendingDelete = c }
                } label: { Label("Delete", systemImage: "trash") }
                .disabled(selectedContact == nil || !vm.isSignedIn)
                Button("Reload") { Task { await vm.refresh() } }
            }
            .padding(.horizontal, 20).padding(.bottom, 10)

            if let e = vm.contactsError {
                Label(e, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
                    .padding(.horizontal, 20).padding(.bottom, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if contacts.isEmpty {
                if !vm.isSignedIn && vm.contacts.isEmpty {
                    ContentUnavailableView("Sign-in required",
                                           systemImage: "person.badge.key",
                                           description: Text("This printer serves its address book only to an administrator."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView("No contacts",
                                           systemImage: "person.crop.circle",
                                           description: Text("This printer's address book is empty."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                Table(contacts, selection: $selected) {
                    TableColumn("★") { c in
                        StarButton(isOn: c.favorite,
                                   busy: vm.favouritesInFlight.contains(c.contactId),
                                   enabled: vm.isSignedIn,
                                   help: c.favorite ? "Favourite on this printer" : "Not a favourite") {
                            Task { await vm.setFavourite(c, to: !c.favorite) }
                        }
                    }
                    .width(28)
                    TableColumn("Name") { Text($0.name) }
                    TableColumn("Company") { Text($0.company.isEmpty ? "—" : $0.company) }
                    TableColumn("Kind") { c in
                        Text(c.contactType.capitalized)
                    }
                    TableColumn("Channels") { c in
                        Text(c.destinations.map(\.label).joined(separator: ", "))
                            .foregroundStyle(.secondary)
                    }
                    TableColumn("Destination") { c in
                        Text(c.summary.isEmpty ? "—" : c.summary)
                            .textSelection(.enabled)
                    }
                    TableColumn("") { c in
                        HStack(spacing: 2) {
                            Button { editing = c } label: { Image(systemName: "square.and.pencil") }
                                .help("Edit \(c.name)")
                            Button(role: .destructive) { pendingDelete = c }
                                label: { Image(systemName: "trash") }
                                .help("Delete \(c.name)")
                        }
                        .buttonStyle(.borderless)
                        .disabled(!vm.isSignedIn)
                    }
                    .width(min: 62, ideal: 62, max: 62)
                }
                .padding(.horizontal, 20)
            }

            HStack {
                Text("\(contacts.count) contacts · \(vm.contacts.filter(\.favorite).count) favourite")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .sheet(item: $editing) { c in
            ContactEditor(contact: c, printers: [vm.printer.name]) { name, company, email in
                await vm.updateContact(c, displayName: name, company: company, email: email)
            }
        }
        .alert(item: $pendingDelete) { c in
            Alert(title: Text("Delete \(c.name) from \(vm.printer.name)?"),
                  message: Text("This removes the address book entry from the printer. It cannot be undone."),
                  primaryButton: .destructive(Text("Delete")) {
                      Task { await vm.deleteContact(c) }
                  },
                  secondaryButton: .cancel())
        }
    }
}

/// Address book across the fleet, keyed by destination so the same person on several
/// printers is one row -- matching how the Users view merges accounts.
struct FleetAddressBookView: View {
    @EnvironmentObject var fleet: Fleet
    @State private var search = ""
    @State private var onlyIncomplete = false
    @State private var favouritesOnly = false
    @State private var busyContacts: Set<String> = []
    @State private var favouriteError: String?
    @State private var editing: MergedContact?
    @State private var pendingDelete: MergedContact?
    @State private var selected: MergedContact.ID?

    private var readable: [DeviceViewModel] {
        fleet.ordered().filter { $0.isSignedIn || !$0.contacts.isEmpty }
    }

    private var selectedContact: MergedContact? {
        selected.flatMap { id in merged.first { $0.id == id } }
    }


    /// Brings every printer holding this contact into line.
    ///
    /// A contact starred on two printers out of three is neither on nor off, so the
    /// click resolves it: anything short of "favourite everywhere" becomes favourite
    /// everywhere, and only a contact already starred on all of them is cleared. That
    /// makes the half-state reachable by the device panel but never left behind here.
    private func toggleAcrossFleet(_ c: MergedContact) async {
        guard !busyContacts.contains(c.key) else { return }
        busyContacts.insert(c.key)
        favouriteError = nil
        defer { busyContacts.remove(c.key) }

        let wanted = !c.isFavouriteEverywhere
        var failed: [String] = []
        for vm in readable {
            guard let record = c.sources[vm.printer.id], record.favorite != wanted else { continue }
            if await !vm.setFavourite(record, to: wanted) {
                failed.append(vm.printer.name)
            }
        }
        if !failed.isEmpty {
            favouriteError = "Could not change \(c.name) on " + failed.joined(separator: ", ") + "."
        }
    }

    struct MergedContact: Identifiable {
        let key: String
        var name: String
        var company: String
        var channels: Set<String>
        var target: String
        var presentOn: Set<UUID>
        /// Favourite status is per printer, so record where rather than flattening it.
        var favouriteOn: Set<UUID>
        /// The record each printer holds. ContactId is per device, so writing this
        /// contact fleet-wide means writing a different id on every printer.
        var sources: [UUID: Contact]
        var id: String { key }

        var isFavouriteAnywhere: Bool { !favouriteOn.isEmpty }
        var isFavouriteEverywhere: Bool { !presentOn.isEmpty && favouriteOn == presentOn }
    }

    private var merged: [MergedContact] {
        var map: [String: MergedContact] = [:]
        for vm in readable {
            for c in vm.contacts {
                var entry = map[c.fleetKey] ?? MergedContact(key: c.fleetKey, name: c.name,
                                                             company: c.company, channels: [],
                                                             target: c.summary, presentOn: [],
                                                             favouriteOn: [], sources: [:])
                if entry.name.isEmpty { entry.name = c.name }
                if entry.company.isEmpty { entry.company = c.company }
                entry.channels.formUnion(c.destinations.map(\.label))
                entry.presentOn.insert(vm.printer.id)
                if c.favorite { entry.favouriteOn.insert(vm.printer.id) }
                entry.sources[vm.printer.id] = c
                map[c.fleetKey] = entry
            }
        }
        var list = Array(map.values)
        if favouritesOnly { list = list.filter(\.isFavouriteAnywhere) }
        if onlyIncomplete { list = list.filter { $0.presentOn.count < readable.count } }
        if !search.isEmpty {
            let q = search.lowercased()
            list = list.filter {
                $0.name.lowercased().contains(q) || $0.company.lowercased().contains(q)
                    || $0.target.lowercased().contains(q)
            }
        }
        return list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Address Book").font(.title2).bold()
                if fleet.isLoadingAll { ProgressView().controlSize(.small) }
                Spacer()
                Toggle("Favourites only", isOn: $favouritesOnly).toggleStyle(.checkbox)
                Toggle("Missing from some printers", isOn: $onlyIncomplete).toggleStyle(.checkbox)
                Button {
                    if let c = selectedContact { editing = c }
                } label: { Label("Edit", systemImage: "square.and.pencil") }
                .disabled(selectedContact == nil)
                Button(role: .destructive) {
                    if let c = selectedContact { pendingDelete = c }
                } label: { Label("Delete", systemImage: "trash") }
                .disabled(selectedContact == nil)
                Button { Task { await fleet.refreshAll() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 8)

            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search name, company or address", text: $search)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 20).padding(.bottom, 10)

            if let favouriteError {
                Label(favouriteError, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
                    .padding(.horizontal, 20).padding(.bottom, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if readable.isEmpty {
                ContentUnavailableView("No printers readable",
                                       systemImage: "person.badge.key",
                                       description: Text("Printers need an administrator sign-in before their address books can be listed."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(merged, selection: $selected) {
                    TableColumn("★") { c in
                        StarButton(isOn: c.isFavouriteAnywhere,
                                   partial: c.isFavouriteAnywhere && !c.isFavouriteEverywhere,
                                   busy: busyContacts.contains(c.key),
                                   enabled: true,
                                   help: c.isFavouriteEverywhere ? "Favourite on every printer"
                                       : c.isFavouriteAnywhere
                                         ? "Favourite on \(c.favouriteOn.count) of \(c.presentOn.count) — click to set on all"
                                         : "Not a favourite") {
                            Task { await toggleAcrossFleet(c) }
                        }
                    }
                    .width(28)
                    TableColumn("Name") { Text($0.name) }
                    TableColumn("Company") { Text($0.company.isEmpty ? "—" : $0.company) }
                    TableColumn("Channels") { c in
                        Text(c.channels.sorted().joined(separator: ", ")).foregroundStyle(.secondary)
                    }
                    TableColumn("Destination") { c in
                        Text(c.target.isEmpty ? "—" : c.target).textSelection(.enabled)
                    }
                    TableColumn("On") { c in
                        Text("\(c.presentOn.count)/\(readable.count)")
                            .monospacedDigit()
                            .foregroundStyle(c.presentOn.count == readable.count
                                             ? Color.secondary : Color.orange)
                    }
                    .width(min: 40, ideal: 44, max: 60)
                    TableColumn("Printers") { c in
                        HStack(spacing: 4) {
                            ForEach(readable, id: \.printer.id) { vm in
                                Image(systemName: c.presentOn.contains(vm.printer.id)
                                      ? "checkmark.circle.fill" : "circle.dotted")
                                    .foregroundStyle(c.presentOn.contains(vm.printer.id)
                                                     ? Color.green : Color.secondary.opacity(0.5))
                                    .help(vm.printer.name)
                            }
                        }
                    }
                    TableColumn("") { c in
                        HStack(spacing: 2) {
                            Button { editing = c } label: { Image(systemName: "square.and.pencil") }
                                .help("Edit on \(c.presentOn.count) printer(s)")
                            Button(role: .destructive) { pendingDelete = c }
                                label: { Image(systemName: "trash") }
                                .help("Delete from \(c.presentOn.count) printer(s)")
                        }
                        .buttonStyle(.borderless)
                        .disabled(busyContacts.contains(c.key))
                    }
                    .width(min: 62, ideal: 62, max: 62)
                }
                .padding(.horizontal, 20)
            }

            // With nothing readable the legend would name no columns; the empty state
            // already explains why.
            if !readable.isEmpty {
                HStack {
                    Text("Printer columns, in order: "
                         + readable.map(\.printer.name).joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 20).padding(.vertical, 10)
            }
        }
        .sheet(item: $editing) { c in
            FleetContactEditor(title: c.name, sources: c.sources, devices: readable)
        }
        .alert(item: $pendingDelete) { c in
            Alert(title: Text("Delete \(c.name) from \(c.presentOn.count) printer(s)?"),
                  message: Text("This removes the address book entry from "
                                + readable.filter { c.presentOn.contains($0.printer.id) }
                                    .map(\.printer.name).joined(separator: ", ")
                                + ". It cannot be undone."),
                  primaryButton: .destructive(Text("Delete")) {
                      Task { await deleteAcrossFleet(c) }
                  },
                  secondaryButton: .cancel())
        }
        .task { await fleet.connectAll() }
    }

    /// Removing from several printers can half succeed, so the shortfall is reported
    /// rather than left for the operator to notice on the next reload.
    private func deleteAcrossFleet(_ c: MergedContact) async {
        busyContacts.insert(c.key)
        favouriteError = nil
        defer { busyContacts.remove(c.key) }

        var removed: [String] = []
        var failed: [String] = []
        for vm in readable {
            guard let record = c.sources[vm.printer.id] else { continue }
            if await vm.deleteContact(record) { removed.append(vm.printer.name) }
            else { failed.append(vm.printer.name) }
        }
        if !failed.isEmpty {
            let kept = removed.isEmpty ? "" : " Removed from " + removed.joined(separator: ", ") + "."
            favouriteError = "Could not remove \(c.name) from " + failed.joined(separator: ", ") + "." + kept
        }
    }
}

/// The star in a table row. A plain `Image` looked identical but did nothing, which is
/// what made favourites read as broken rather than as read-only.
///
/// `partial` is for the fleet view, where a contact starred on some printers but not all
/// is neither state: it is drawn half-strength so it cannot be mistaken for either.
struct StarButton: View {
    let isOn: Bool
    var partial: Bool = false
    var busy: Bool = false
    var enabled: Bool = true
    var help: String
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            if busy {
                ProgressView().controlSize(.small).scaleEffect(0.6)
            } else {
                Image(systemName: isOn ? "star.fill" : "star")
                    .foregroundStyle(isOn
                                     ? Color.yellow.opacity(partial ? 0.45 : 1)
                                     : Color.secondary.opacity(0.35))
            }
        }
        .buttonStyle(.borderless)
        .disabled(busy || !enabled)
        .help(enabled ? help : "Sign in as an administrator to change favourites")
    }
}

/// Edits one contact: the fields this app models, not everything the device holds.
///
/// A contact may carry fax, internet-fax and server destinations that are never shown
/// here. The write sends back the record the device returned with only these fields
/// altered, so those other destinations survive untouched rather than being dropped by
/// an editor that never knew about them.
struct ContactEditor: View {
    let contact: Contact
    /// The printers this edit will be written to, named. "2 printer(s)" told the
    /// operator how many devices they were about to change but not which, which is the
    /// part that matters when the write cannot be undone.
    let printers: [String]
    let save: (String, String, String) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var company: String
    @State private var email: String
    @State private var saving = false
    @State private var failed = false

    init(contact: Contact, printers: [String],
         save: @escaping (String, String, String) async -> Bool) {
        self.contact = contact
        self.printers = printers
        self.save = save
        _name = State(initialValue: contact.displayName.isEmpty ? contact.name : contact.displayName)
        _company = State(initialValue: contact.company)
        _email = State(initialValue: contact.destinations
            .first { $0.type.uppercased() == "EMAIL" }?.target ?? "")
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
    private var otherChannels: [Destination] {
        contact.destinations.filter { $0.type.uppercased() != "EMAIL" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Edit Contact").font(.title2).bold()
                Text(printers.isEmpty ? "no printers"
                     : "on " + printers.joined(separator: ", "))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Form {
                TextField("Name", text: $name, prompt: Text("Full name"))
                TextField("Company", text: $company, prompt: Text("Optional"))
                TextField("Email", text: $email, prompt: Text("name@example.school.nz"))
            }
            .formStyle(.grouped)

            if !otherChannels.isEmpty {
                Text("This contact also has "
                     + otherChannels.map(\.label).joined(separator: ", ")
                     + " destinations. They are left as they are.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if failed {
                Label("The printer did not store the change.", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
            }

            HStack {
                if saving { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    Task {
                        saving = true; failed = false
                        let ok = await save(trimmedName,
                                            company.trimmingCharacters(in: .whitespaces),
                                            email.trimmingCharacters(in: .whitespaces))
                        saving = false
                        if ok { dismiss() } else { failed = true }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedName.isEmpty || saving)
            }
        }
        .padding(20).frame(width: 460)
    }
}

/// Edits one contact across the fleet: its details, and which printers hold it.
///
/// Ticking a printer creates the entry there; unticking deletes it from that device.
/// Removal is confirmed separately and never applied as a side effect of saving a name
/// change -- the same rule the fleet user editor follows, and for the same reason.
///
/// Adding requires an email address, because a contact with no destination cannot be
/// scanned to; the device accepts one and it simply sits there being useless.
struct FleetContactEditor: View {
    let title: String
    let sources: [UUID: Contact]
    let devices: [DeviceViewModel]

    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var company: String
    @State private var email: String
    @State private var membership: Set<UUID>
    @State private var running = false
    @State private var finished = false
    @State private var confirmRemovals = false
    @State private var results: [UUID: String] = [:]

    private let originalOn: Set<UUID>
    private let originalName: String
    private let originalCompany: String
    private let originalEmail: String

    init(title: String, sources: [UUID: Contact], devices: [DeviceViewModel]) {
        self.title = title
        self.sources = sources
        self.devices = devices

        let sample = sources.values.first
        let n = sample?.displayName.isEmpty == false ? sample!.displayName : (sample?.name ?? title)
        let c = sample?.company ?? ""
        let e = sample?.destinations.first { $0.type.uppercased() == "EMAIL" }?.target ?? ""
        _name = State(initialValue: n)
        _company = State(initialValue: c)
        _email = State(initialValue: e)
        _membership = State(initialValue: Set(sources.keys))
        originalOn = Set(sources.keys)
        originalName = n
        originalCompany = c
        originalEmail = e
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
    private var trimmedEmail: String { email.trimmingCharacters(in: .whitespaces) }
    private var additions: [DeviceViewModel] {
        devices.filter { membership.contains($0.printer.id) && !originalOn.contains($0.printer.id) }
    }
    private var removals: [DeviceViewModel] {
        devices.filter { !membership.contains($0.printer.id) && originalOn.contains($0.printer.id) }
    }
    private var detailsChanged: Bool {
        trimmedName != originalName
            || company.trimmingCharacters(in: .whitespaces) != originalCompany
            || trimmedEmail != originalEmail
    }
    private var hasWork: Bool { detailsChanged || !additions.isEmpty || !removals.isEmpty }
    private var addingWithoutAddress: Bool { !additions.isEmpty && trimmedEmail.isEmpty }
    /// Unticking the last printer is not "remove from two printers", it is "this contact
    /// stops existing". Worth saying plainly, because nothing else in the sheet does.
    private var removingEverywhere: Bool { membership.isEmpty && !removals.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title2).bold()
                Text("on \(originalOn.count) of \(devices.count) printers")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Form {
                TextField("Name", text: $name, prompt: Text("Full name"))
                TextField("Company", text: $company, prompt: Text("Optional"))
                TextField("Email", text: $email, prompt: Text("name@example.school.nz"))
            }
            .formStyle(.grouped)

            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Button("All") { membership = Set(devices.map(\.printer.id)) }
                        Button("None") { membership = [] }
                        Spacer()
                        Text("\(membership.count) of \(devices.count)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Divider()
                    ForEach(devices, id: \.printer.id) { vm in
                        ContactMembershipRow(vm: vm,
                                             isOn: membership.contains(vm.printer.id),
                                             was: originalOn.contains(vm.printer.id),
                                             result: results[vm.printer.id]) {
                            if membership.contains(vm.printer.id) { membership.remove(vm.printer.id) }
                            else { membership.insert(vm.printer.id) }
                        }
                    }
                }
            } label: { Label("Printers", systemImage: "printer.dotmatrix") }

            if addingWithoutAddress {
                Label("An email address is needed to add this contact to a printer — an entry with no destination cannot be scanned to.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if removingEverywhere {
                Label("This will delete \(trimmedName) from every printer. The contact will no longer exist anywhere in the fleet.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !removals.isEmpty {
                Label("Unticking deletes the entry from "
                      + removals.map(\.printer.name).joined(separator: ", ") + ".",
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
                .disabled(!hasWork || running || trimmedName.isEmpty || addingWithoutAddress)
            }
        }
        .padding(20)
        .frame(width: 580)
        .alert(removingEverywhere
               ? "Remove \(trimmedName) from every printer?"
               : "Delete \(trimmedName) from \(removals.count) printer(s)?",
               isPresented: $confirmRemovals) {
            Button(removingEverywhere ? "Remove Everywhere" : "Delete",
                   role: .destructive) { Task { await apply() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(removingEverywhere
                 ? "This deletes the address book entry from "
                   + removals.map(\.printer.name).joined(separator: ", ")
                   + ", leaving it on none of them. It cannot be undone."
                 : "This removes the address book entry from "
                   + removals.map(\.printer.name).joined(separator: ", ") + ". It cannot be undone.")
        }
    }

    private func apply() async {
        running = true; results = [:]
        defer { running = false; finished = true }

        let company = company.trimmingCharacters(in: .whitespaces)
        for vm in devices {
            let held = sources[vm.printer.id]
            let wanted = membership.contains(vm.printer.id)

            if wanted, let held {
                guard detailsChanged else { continue }
                results[vm.printer.id] = await vm.updateContact(held, displayName: trimmedName,
                                                                company: company, email: trimmedEmail)
                    ? "updated" : (vm.contactsError ?? "could not update")
            } else if wanted {
                results[vm.printer.id] = await vm.addContact(named: trimmedName, email: trimmedEmail)
                    ? "added" : (vm.contactsError ?? "could not add")
            } else if let held {
                results[vm.printer.id] = await vm.deleteContact(held)
                    ? "removed" : (vm.contactsError ?? "could not remove")
            }
        }
    }
}

private struct ContactMembershipRow: View {
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
