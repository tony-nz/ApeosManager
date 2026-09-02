import SwiftUI

struct DeviceSettingsView: View {
    @ObservedObject var vm: DeviceViewModel
    @State private var draft = DeviceAbout()
    @State private var saving = false
    @State private var saved = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !vm.isSignedIn {
                    Label("Sign in as administrator to change these settings.",
                          systemImage: "lock")
                        .font(.callout).foregroundStyle(.secondary)
                }

                GroupBox("Identity") {
                    Form {
                        TextField("Friendly name", text: $draft.devFrndlName)
                        TextField("Location", text: $draft.location)
                        TextField("Comment", text: $draft.comment)
                    }
                    .formStyle(.columns)
                }

                GroupBox("Administrator Contact") {
                    Form {
                        TextField("Name", text: $draft.adminName)
                        TextField("Email", text: $draft.adminEmail)
                        TextField("Phone", text: $draft.adminPhone)
                        TextField("Location", text: $draft.adminLocation)
                    }
                    .formStyle(.columns)
                }

                GroupBox("Read-only") {
                    Form {
                        LabeledContent("Host name", value: draft.hostName)
                        LabeledContent("Serial number", value: draft.serialNumber)
                        LabeledContent("Firmware", value: draft.softwareVersion)
                        LabeledContent("IP address", value: draft.ipv4PrimaryAddress)
                        LabeledContent("Device email", value: draft.localEmail)
                    }
                    .formStyle(.columns)
                }

                HStack {
                    if saving { ProgressView().controlSize(.small) }
                    if saved { Label("Saved", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                    Spacer()
                    Button("Revert") { if let a = vm.about { draft = a }; saved = false }
                    Button("Save Changes") {
                        Task {
                            saving = true; saved = false
                            await vm.saveIdentity(draft)
                            saving = false
                            saved = vm.errorMessage == nil
                        }
                    }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!vm.isSignedIn || saving)
                }

                if let e = vm.errorMessage {
                    Text(e).font(.callout).foregroundStyle(.red)
                }
            }
            .padding(20)
            .frame(maxWidth: 640, alignment: .leading)
        }
        .onAppear { if let a = vm.about { draft = a } }
        .onChange(of: vm.about?.serialNumber) { if let a = vm.about { draft = a } }
    }
}
