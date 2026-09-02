import SwiftUI

enum SidebarItem: Hashable {
    case fleetOverview
    case fleetUsers
    case fleetLogs
    case fleetAddressBook
    case printer(UUID)
}

struct ContentView: View {
    @EnvironmentObject var store: PrinterStore
    @EnvironmentObject var fleet: Fleet
    @State private var selection: SidebarItem? = .fleetOverview
    @State private var showingAdd = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("All Printers") {
                    Label("Overview", systemImage: "square.grid.2x2")
                        .tag(SidebarItem.fleetOverview)
                    Label("Users", systemImage: "person.2")
                        .tag(SidebarItem.fleetUsers)
                    Label("Address Book", systemImage: "book.closed")
                        .tag(SidebarItem.fleetAddressBook)
                    Label("Logs", systemImage: "doc.text.magnifyingglass")
                        .tag(SidebarItem.fleetLogs)
                }
                Section("Printers") {
                    ForEach(store.printers) { p in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.name)
                            Text(p.host).font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(SidebarItem.printer(p.id))
                        .contextMenu {
                            Button("Remove", role: .destructive) {
                                fleet.drop(p)
                                store.remove(p)
                                selection = .fleetOverview
                            }
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 240)
            .toolbar {
                Button { showingAdd = true } label: { Label("Add Printer", systemImage: "plus") }
            }
        } detail: {
            switch selection {
            case .fleetOverview:
                FleetOverviewView()
            case .fleetUsers:
                FleetUsersView()
            case .fleetAddressBook:
                FleetAddressBookView()
            case .fleetLogs:
                FleetLogsView()
            case .printer(let id):
                if let printer = store.printers.first(where: { $0.id == id }) {
                    DeviceDetailView(vm: fleet.viewModel(for: printer)).id(id)
                } else {
                    ContentUnavailableView("Printer Removed", systemImage: "printer")
                }
            case nil:
                ContentUnavailableView("Nothing Selected", systemImage: "printer")
            }
        }
        .sheet(isPresented: $showingAdd) { AddPrinterSheet() }
    }
}
