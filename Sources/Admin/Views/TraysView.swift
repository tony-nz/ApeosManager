import SwiftUI

struct TraysView: View {
    @ObservedObject var vm: DeviceViewModel

    var body: some View {
        Table(vm.trays) {
            TableColumn("Tray") { t in Text(TrayFormat.title(t)) }
            TableColumn("Size") { t in Text(t.mediumSize ?? "—") }
            TableColumn("Type") { t in Text(TrayFormat.type(t.mediumType)) }
            TableColumn("Colour") { t in Text(t.mediumColor?.capitalized ?? "—") }
            TableColumn("Level") { t in
                // A model that cannot measure its trays still reports a Volume; it just
                // means nothing, so read the level only where detection is confirmed.
                TrayLevel(level: vm.trayVolumeDetection == false ? nil : TrayFormat.level(t))
            }
            .width(110)
            TableColumn("Status") { t in
                Text(t.status?.replacingOccurrences(of: "_", with: " ").capitalized ?? "—")
            }
        }
        .padding(20)
    }
}

/// How much paper is left in one tray, as a percentage of full.
struct TrayLevel: View {
    let level: Int?

    private static let barWidth: CGFloat = 54

    var body: some View {
        if let level {
            HStack(spacing: 7) {
                Capsule().fill(Color.secondary.opacity(0.18))
                    .frame(width: Self.barWidth, height: 6)
                    .overlay(alignment: .leading) {
                        // Zero stays empty rather than showing a stub of colour.
                        Capsule().fill(TrayFormat.colour(level))
                            .frame(width: level == 0 ? 0
                                                     : max(3, Self.barWidth * CGFloat(level) / 100),
                                   height: 6)
                    }
                // An empty tray has no bar to colour, so the figure carries the state.
                Text("\(level)%")
                    .monospacedDigit()
                    .foregroundStyle(level < 26 ? TrayFormat.colour(level) : .secondary)
                    .frame(width: 44, alignment: .trailing)
            }
            .help(level == 0 ? "Empty" : "\(level)% of a full tray")
        } else {
            Text("—")
        }
    }
}
