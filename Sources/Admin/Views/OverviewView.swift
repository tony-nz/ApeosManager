import SwiftUI

struct OverviewView: View {
    @ObservedObject var vm: DeviceViewModel

    private var toners: [Supply] { vm.supplies.filter { $0.family == "TONER" } }
    private var others: [Supply] { vm.supplies.filter { $0.family != "TONER" } }
    /// Only trays the device measured. Models without the sensor answer with a
    /// negative sentinel, and a bypass reports one even where the cassettes are read.
    private var trays: [PaperTray] {
        vm.trayVolumeDetection == false ? [] : vm.trays.filter { $0.remaining != nil }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let e = vm.errorMessage {
                    Label(e, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).font(.callout)
                }
                if let n = vm.notice {
                    Label(n, systemImage: "info.circle")
                        .foregroundStyle(.secondary).font(.callout)
                }

                if !vm.suppliesNeedingAttention.isEmpty {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(vm.suppliesNeedingAttention) { s in
                                HStack(spacing: 8) {
                                    Image(systemName: s.isSpent ? "exclamationmark.octagon.fill"
                                                                : "exclamationmark.triangle.fill")
                                        .foregroundStyle(s.isSpent ? .red : .orange)
                                    Text(SupplyFormat.title(s)).bold()
                                    Text(s.isSpent ? "needs replacing now"
                                                   : "\(s.remaining ?? 0)% remaining"
                                                     + (s.pageRemaining.map { " (~\($0) pages)" } ?? ""))
                                        .foregroundStyle(.secondary)
                                }
                                .font(.callout)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } label: { Label("Needs Attention", systemImage: "bell.badge") }
                }

                // Toner and paper side by side: both answer "can this printer run the
                // job in front of me", and reading them together is the point.
                if !toners.isEmpty || !trays.isEmpty {
                    HStack(alignment: .top, spacing: 44) {
                        if !toners.isEmpty { section("Toner") {
                            HStack(alignment: .top, spacing: 18) {
                                ForEach(toners) { SupplyGauge(supply: $0) }
                            }
                        } }

                        if !trays.isEmpty { section("Paper") {
                            HStack(alignment: .top, spacing: 18) {
                                ForEach(trays) { TrayGauge(tray: $0) }
                            }
                        } }

                        Spacer(minLength: 0)
                    }
                }

                if !others.isEmpty {
                    section("Drums & Other Consumables") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 12)],
                                  alignment: .leading, spacing: 10) {
                            ForEach(others) { SupplyRow(supply: $0) }
                        }
                    }
                }

                if !vm.counters.isEmpty {
                    section("Usage Counters") {
                        let groups = Dictionary(grouping: vm.counters, by: \.group)
                        // A device reports a different number of counters per group --
                        // three totals, one fax. Every box stands as tall as the fullest
                        // group so the grid reads as a grid rather than a ragged wall.
                        let tallest = groups.values.map(\.count).max() ?? 1
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)],
                                  alignment: .leading, spacing: 12) {
                            ForEach(groups.keys.sorted(), id: \.self) { key in
                                GroupBox(key.capitalized) {
                                    VStack(spacing: Self.counterRowSpacing) {
                                        ForEach(groups[key] ?? []) { c in
                                            HStack {
                                                Text(c.label.replacingOccurrences(of: "\(key.capitalized) ", with: ""))
                                                    .foregroundStyle(.secondary)
                                                Spacer()
                                                Text(c.count, format: .number).monospacedDigit()
                                            }
                                            .font(.callout)
                                        }
                                        Spacer(minLength: 0)
                                    }
                                    .frame(maxWidth: .infinity,
                                           minHeight: Self.counterBoxHeight(rows: tallest),
                                           alignment: .topLeading)
                                }
                            }
                        }
                    }
                }

                if let d = vm.lastRefresh {
                    Text("Updated \(d.formatted(date: .omitted, time: .standard))")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
            .padding(20)
        }
    }

    private static let counterRowHeight: CGFloat = 17
    private static let counterRowSpacing: CGFloat = 4

    private static func counterBoxHeight(rows: Int) -> CGFloat {
        CGFloat(rows) * counterRowHeight + CGFloat(max(0, rows - 1)) * counterRowSpacing
    }

    @ViewBuilder
    private func section<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }
    }
}

enum SupplyFormat {
    static let colourNames = ["C": "Cyan", "M": "Magenta", "Y": "Yellow", "K": "Black"]

    static func title(_ s: Supply) -> String {
        let fam = s.family.capitalized
        if let c = s.colourCode, let named = colourNames[c] { return "\(fam) \(named)" }
        return s.name.replacingOccurrences(of: "_", with: " ").capitalized
    }

    static func colour(_ s: Supply) -> Color {
        switch s.colourCode {
        case "C": return .cyan
        case "M": return Color(red: 0.85, green: 0.16, blue: 0.55)
        case "Y": return .yellow
        case "K": return .primary
        default:  return .gray
        }
    }
}

enum TrayFormat {
    /// The number the printer prints on the tray itself, and shows in its web UI.
    static func number(_ t: PaperTray) -> String { "\(t.physicalNum ?? t.logicalNum)" }

    /// "1_TRAY" -> "Tray 1", "5_SMH" -> "Bypass". SMH is the side manual handler, which
    /// every operator calls the bypass tray.
    static func title(_ t: PaperTray) -> String {
        switch t.logicalTrayType {
        case "SMH": return "Bypass"
        case "TRAY": return "Tray \(t.physicalNum ?? t.logicalNum)"
        default:
            return t.nameId.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// "A4 Plain", as much of it as the device reported.
    static func media(_ t: PaperTray) -> String {
        [t.mediumSize, type(t.mediumType)].compactMap { $0 }
            .filter { !$0.isEmpty && $0 != "—" }
            .joined(separator: " ")
    }

    /// Firmware reports camelCase media types ("heavyWeight2_reverse_").
    static func type(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "—" }
        let spaced = raw.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "([a-z])([A-Z0-9])", with: "$1 $2",
                                  options: .regularExpression)
        return spaced.trimmingCharacters(in: .whitespaces).capitalized
    }

    /// Empty is the state worth interrupting someone for; low is worth a warning. A
    /// tray with paper in it is not a colour, it is just paper.
    static func colour(_ level: Int) -> Color {
        switch level {
        case 0:     return .red
        case ..<26: return .orange
        default:    return .primary.opacity(0.42)
        }
    }

    static func level(_ t: PaperTray) -> Int? { t.remaining }
}

struct SupplyGauge: View {
    let supply: Supply

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.secondary.opacity(0.18))
                    .frame(width: 56, height: 96)
                RoundedRectangle(cornerRadius: 5)
                    .fill(SupplyFormat.colour(supply))
                    .frame(width: 56, height: max(3, 96 * CGFloat(supply.remaining ?? 0) / 100))
            }
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator))
            Text("\(supply.remaining ?? 0)%").font(.callout).bold().monospacedDigit()
            Text(SupplyFormat.title(supply)).font(.caption).foregroundStyle(.secondary)
            if let p = supply.pageRemaining {
                Text("~\(p) pages").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .help(supply.dateInstalled.map { "Installed \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "")
    }
}

/// One tray, drawn the way the device draws it: a sheet stack seen edge-on, filled
/// from the bottom.
struct TrayGauge: View {
    let tray: PaperTray

    // Matched to SupplyGauge: side by side, two gauge sizes read as an accident,
    // and equal ones put every label on a shared baseline.
    private let size = CGSize(width: 56, height: 96)

    var body: some View {
        let level = TrayFormat.level(tray) ?? 0
        VStack(spacing: 6) {
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.secondary.opacity(0.18))
                    .frame(width: size.width, height: size.height)
                // An empty tray draws nothing, so it reads as empty at a glance rather
                // than as a sliver of paper.
                RoundedRectangle(cornerRadius: 5)
                    .fill(TrayFormat.colour(level))
                    .frame(width: size.width,
                           height: level == 0 ? 0 : max(3, size.height * CGFloat(level) / 100))
            }
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator))
            Text("\(level)%")
                .font(.callout).bold().monospacedDigit()
                .foregroundStyle(level < 26 ? TrayFormat.colour(level) : .primary)
            Text(TrayFormat.title(tray)).font(.caption).foregroundStyle(.secondary)
            Text(TrayFormat.media(tray)).font(.caption2).foregroundStyle(.tertiary)
        }
        .help(statusText)
    }

    private var statusText: String {
        guard let status = tray.status, !status.isEmpty else { return TrayFormat.media(tray) }
        return status.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

struct SupplyRow: View {
    let supply: Supply

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(SupplyFormat.colour(supply)).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(SupplyFormat.title(supply)).font(.callout)
                Text(supply.lifeState.replacingOccurrences(of: "_", with: " ").capitalized)
                    .font(.caption)
                    .foregroundStyle(supply.isSpent ? .red : .secondary)
            }
            Spacer()
            Text("\(supply.remaining ?? 0)%").monospacedDigit().font(.callout)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.secondary.opacity(0.07)))
    }
}
