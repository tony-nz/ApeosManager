import SwiftUI

struct OverviewView: View {
    @ObservedObject var vm: DeviceViewModel

    private var toners: [Supply] { vm.supplies.filter { $0.family == "TONER" } }
    private var others: [Supply] { vm.supplies.filter { $0.family != "TONER" } }

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

                if !toners.isEmpty { section("Toner") {
                    HStack(alignment: .top, spacing: 18) {
                        ForEach(toners) { SupplyGauge(supply: $0) }
                        Spacer(minLength: 0)
                    }
                } }

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
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)],
                                  alignment: .leading, spacing: 12) {
                            ForEach(groups.keys.sorted(), id: \.self) { key in
                                GroupBox(key.capitalized) {
                                    VStack(spacing: 4) {
                                        ForEach(groups[key] ?? []) { c in
                                            HStack {
                                                Text(c.label.replacingOccurrences(of: "\(key.capitalized) ", with: ""))
                                                    .foregroundStyle(.secondary)
                                                Spacer()
                                                Text(c.count, format: .number).monospacedDigit()
                                            }
                                            .font(.callout)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
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
