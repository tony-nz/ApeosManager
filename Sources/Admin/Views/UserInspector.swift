import SwiftUI

/// Everything held against one user on one printer, in a single sheet: the record
/// itself, the accounting meters, and what the user may do at the panel.
///
/// These were three separate sheets opened from three buttons crowded into the last
/// column of the user table. Three narrow buttons per row is a lot of furniture for a
/// list whose rows are mostly read, and comparing a user's limits against their
/// permissions meant closing one sheet to open another. One sheet with three panes
/// costs the table a single icon and keeps the comparison a click apart.
///
/// Each pane keeps its own footer, because the three saves are not one operation: the
/// record is written by `SetUserInformation`, the meters by an accounting write, and
/// the permissions by a third call that may need confirming before it grants
/// administrator rights. A single Save would have to decide what "save everything"
/// means when only one pane was touched, and would hide which write failed.
struct UserInspector: View {
    let user: DeviceUser
    @ObservedObject var vm: DeviceViewModel
    let existingIDs: Set<String>
    let onSaveUser: (DeviceUser, String?) -> Void

    @State private var pane: Pane = .details

    enum Pane: String, CaseIterable, Identifiable {
        case details = "Details"
        case usage = "Usage"
        case permissions = "Permissions"

        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .details:     return "person.text.rectangle"
            case .usage:       return "chart.bar"
            case .permissions: return "lock.shield"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(user.displayName).font(.title2).bold()
                Text("\(user.userID) on \(vm.printer.name)")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Picker("", selection: $pane) {
                ForEach(Pane.allCases) { p in
                    Label(p.rawValue, systemImage: p.symbol).tag(p)
                }
            }
            .pickerStyle(.segmented).labelsHidden()

            switch pane {
            case .details:
                UserEditor(user: user, isNew: false, existingIDs: existingIDs,
                           embedded: true, onSave: onSaveUser)
            case .usage:
                UsageEditor(user: user, vm: vm, embedded: true)
            case .permissions:
                PermissionsEditor(user: user, vm: vm, embedded: true)
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        // A fixed height for all three panes: they differ enough in content that letting
        // the sheet size itself would resize the window on every tab click.
        .frame(width: 560, height: 520, alignment: .topLeading)
    }
}
