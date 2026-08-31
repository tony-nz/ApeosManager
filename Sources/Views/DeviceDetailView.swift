import SwiftUI

struct DeviceDetailView: View {
    @EnvironmentObject var store: PrinterStore
    @ObservedObject var vm: DeviceViewModel
    @State private var tab = Tab.overview
    @State private var showSignIn = false

    enum Tab: String, CaseIterable, Identifiable {
        case overview = "Overview", trays = "Trays", settings = "Settings", accounts = "Accounts", addressBook = "Address Book", logs = "Logs"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .overview: return "chart.bar.doc.horizontal"
            case .trays:    return "tray.2"
            case .settings: return "gearshape"
            case .accounts: return "person.2"
            case .addressBook: return "book.closed"
            case .logs:     return "doc.text.magnifyingglass"
            }
        }
    }



    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            TabView(selection: $tab) {
                ForEach(Tab.allCases) { t in
                    Group {
                        switch t {
                        case .overview: OverviewView(vm: vm)
                        case .trays:    TraysView(vm: vm)
                        case .settings: DeviceSettingsView(vm: vm)
                        case .accounts: AccountsView(vm: vm, requestSignIn: { showSignIn = true })
                        case .addressBook: AddressBookView(vm: vm)
                        case .logs:     LogsView(vm: vm)
                        }
                    }
                    .tabItem { Label(t.rawValue, systemImage: t.icon) }
                    .tag(t)
                }
            }
            .padding(.top, 8)
        }
        .task { await vm.connect() }
        .sheet(isPresented: $showSignIn) { SignInSheet(vm: vm) }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(vm.about?.devFrndlName ?? vm.printer.name).font(.title2).bold()
                HStack(spacing: 8) {
                    Text(vm.printer.host)
                    if let s = vm.status?.status { Text("•"); Text(s.replacingOccurrences(of: "_", with: " ").capitalized) }
                    if let sn = vm.about?.serialNumber, !sn.isEmpty { Text("•"); Text("S/N \(sn)") }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if vm.isSignedIn {
                Label("Administrator", systemImage: "lock.open")
                    .font(.caption).foregroundStyle(.green)
                Button("Sign Out") { Task { await vm.signOut() } }
            } else {
                Button("Sign In…") { showSignIn = true }
            }
            Button { Task { await vm.refresh() } } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(vm.isLoading)
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
        .overlay(alignment: .bottom) { if vm.isLoading { ProgressView().controlSize(.small) } }
    }

}

struct SignInSheet: View {
    @ObservedObject var vm: DeviceViewModel
    @EnvironmentObject var store: PrinterStore
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var remember = true
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sign in to \(vm.printer.name)").font(.title3).bold()
            Text("Administrator rights are required to read accounting data and change settings.")
                .font(.callout).foregroundStyle(.secondary)
            Form {
                LabeledContent("User ID") { Text(vm.printer.adminUser) }
                SecureField("Password", text: $password)
                Toggle("Remember in keychain", isOn: $remember)
            }
            .formStyle(.grouped)
            if let e = vm.errorMessage { Text(e).font(.callout).foregroundStyle(.red) }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Sign In") {
                    Task {
                        busy = true
                        await vm.signIn(password: password)
                        busy = false
                        if vm.isSignedIn {
                            if remember { store.setPassword(password, for: vm.printer) }
                            dismiss()
                        }
                    }
                }
                .keyboardShortcut(.defaultAction).disabled(password.isEmpty || busy)
            }
        }
        .padding(20).frame(width: 440)
    }
}
