import SwiftUI

struct TraysView: View {
    @ObservedObject var vm: DeviceViewModel

    var body: some View {
        Table(vm.trays) {
            TableColumn("Tray") { t in
                Text(t.nameId.replacingOccurrences(of: "_", with: " ").capitalized)
            }
            TableColumn("Size") { t in Text(t.mediumSize ?? "—") }
            TableColumn("Type") { t in Text(prettyType(t.mediumType)) }
            TableColumn("Colour") { t in Text(t.mediumColor?.capitalized ?? "—") }
            TableColumn("Status") { t in
                Text(t.status?.replacingOccurrences(of: "_", with: " ").capitalized ?? "—")
            }
        }
        .padding(20)
    }

    /// Firmware reports camelCase media types ("heavyWeight2_reverse_").
    private func prettyType(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "—" }
        let spaced = raw.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "([a-z])([A-Z0-9])", with: "$1 $2",
                                  options: .regularExpression)
        return spaced.trimmingCharacters(in: .whitespaces).capitalized
    }
}
