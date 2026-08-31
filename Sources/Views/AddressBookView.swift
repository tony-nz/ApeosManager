import SwiftUI

/// The address book on one printer.
struct AddressBookView: View {
    @ObservedObject var vm: DeviceViewModel
    @State private var search = ""
    @State private var favouritesOnly = false

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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search name, company or address", text: $search)
                    .textFieldStyle(.plain)
                Toggle("Favourites only", isOn: $favouritesOnly).toggleStyle(.checkbox)
                Button("Reload") { Task { await vm.refresh() } }
            }
            .padding(.horizontal, 20).padding(.bottom, 10)

            if contacts.isEmpty {
                if !vm.isSignedIn && vm.contacts.isEmpty {
                    ContentUnavailableView("Sign-in required",
                                           systemImage: "person.badge.key",
                                           description: Text("This printer serves its address book only to an administrator."))
                } else {
                    ContentUnavailableView("No contacts",
                                           systemImage: "person.crop.circle",
                                           description: Text("This printer's address book is empty."))
                }
            } else {
                Table(contacts) {
                    TableColumn("★") { c in
                        Image(systemName: c.favorite ? "star.fill" : "star")
                            .foregroundStyle(c.favorite ? Color.yellow : Color.secondary.opacity(0.35))
                            .help(c.favorite ? "Favourite on this printer" : "Not a favourite")
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
    }
}

/// Address book across the fleet, keyed by destination so the same person on several
/// printers is one row -- matching how the Users view merges accounts.
struct FleetAddressBookView: View {
    @EnvironmentObject var fleet: Fleet
    @State private var search = ""
    @State private var onlyIncomplete = false
    @State private var favouritesOnly = false

    private var readable: [DeviceViewModel] {
        fleet.ordered().filter { $0.isSignedIn || !$0.contacts.isEmpty }
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
                                                             favouriteOn: [])
                if entry.name.isEmpty { entry.name = c.name }
                if entry.company.isEmpty { entry.company = c.company }
                entry.channels.formUnion(c.destinations.map(\.label))
                entry.presentOn.insert(vm.printer.id)
                if c.favorite { entry.favouriteOn.insert(vm.printer.id) }
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

            if readable.isEmpty {
                ContentUnavailableView("No printers readable",
                                       systemImage: "person.badge.key",
                                       description: Text("Printers need an administrator sign-in before their address books can be listed."))
            } else {
                Table(merged) {
                    TableColumn("★") { c in
                        Image(systemName: c.isFavouriteAnywhere ? "star.fill" : "star")
                            .foregroundStyle(c.isFavouriteAnywhere
                                             ? Color.yellow : Color.secondary.opacity(0.35))
                            .help(c.isFavouriteEverywhere ? "Favourite on every printer"
                                  : c.isFavouriteAnywhere
                                    ? "Favourite on \(c.favouriteOn.count) of \(c.presentOn.count)"
                                    : "Not a favourite")
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
                }
                .padding(.horizontal, 20)
            }

            HStack {
                Text("Printer columns, in order: " + readable.map(\.printer.name).joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 20).padding(.vertical, 10)
        }
        .task { await fleet.connectAll() }
    }
}
