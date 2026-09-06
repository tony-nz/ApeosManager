import SwiftUI

/// Status of every printer on one screen: what needs attention first, then a card per
/// device with toner, status and counters.
struct FleetOverviewView: View {
    @EnvironmentObject var store: PrinterStore
    @EnvironmentObject var fleet: Fleet

    private var devices: [DeviceViewModel] { fleet.ordered() }

    private struct Attention: Identifiable {
        let id = UUID()
        let printer: String
        let supply: Supply
    }

    private var attention: [Attention] {
        devices.flatMap { vm in
            vm.suppliesNeedingAttention.map { Attention(printer: vm.printer.name, supply: $0) }
        }
        .sorted { ($0.supply.remaining ?? 0) < ($1.supply.remaining ?? 0) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("All Printers").font(.title2).bold()
                    if fleet.isLoadingAll { ProgressView().controlSize(.small) }
                    Spacer()
                    Button {
                        Task { await fleet.refreshAll() }
                    } label: { Label("Refresh All", systemImage: "arrow.clockwise") }
                }

                if !attention.isEmpty {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 7) {
                            ForEach(attention) { item in
                                HStack(spacing: 8) {
                                    Image(systemName: item.supply.isSpent
                                          ? "exclamationmark.octagon.fill"
                                          : "exclamationmark.triangle.fill")
                                        .foregroundStyle(item.supply.isSpent ? .red : .orange)
                                    Text(item.printer).bold()
                                    Text(SupplyFormat.title(item.supply))
                                    Text(item.supply.isSpent
                                         ? "needs replacing now"
                                         : "\(item.supply.remaining ?? 0)% remaining")
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                }
                                .font(.callout)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } label: { Label("Needs Attention", systemImage: "bell.badge") }
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 330), spacing: 14)],
                          alignment: .leading, spacing: 14) {
                    ForEach(devices, id: \.printer.id) { vm in
                        PrinterCard(vm: vm)
                    }
                }

                if devices.isEmpty {
                    ContentUnavailableView("No Printers",
                                           systemImage: "printer",
                                           description: Text("Add one with + to see it here."))
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(20)
        }
        .task { await fleet.connectAll() }
    }
}

/// Names what a row of gauges is measuring. One fixed width for every row, so the
/// gauges below the label line up with the ones above them.
private struct RowLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(width: 38, alignment: .leading)
            .padding(.top, 2)
    }
}

/// One tray on a fleet card, drawn to the same size as the toner gauge above it so the
/// two rows read as one scale, and numbered the way the device numbers them.
private struct CardTray: View {
    let tray: PaperTray

    var body: some View {
        let level = TrayFormat.level(tray) ?? 0
        VStack(spacing: 3) {
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.secondary.opacity(0.18))
                    .frame(width: 26, height: 44)
                RoundedRectangle(cornerRadius: 3)
                    .fill(TrayFormat.colour(level))
                    .frame(width: 26, height: level == 0 ? 0 : max(2, 44 * CGFloat(level) / 100))
            }
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.separator))
            Text(TrayFormat.number(tray))
                .font(.caption2).monospacedDigit()
                .foregroundStyle(level < 26 ? TrayFormat.colour(level) : .secondary)
        }
        .help("\(TrayFormat.title(tray)) — \(TrayFormat.media(tray)), \(level)%")
    }
}

private struct PrinterCard: View {
    @ObservedObject var vm: DeviceViewModel

    /// One gauge row: the block, the gap under it, and its number.
    private static let gaugeRow: CGFloat = 44 + 3 + 14
    /// Every card stands as tall as a full one -- name, toner row, rule, paper row --
    /// so an offline printer, or one whose trays cannot be measured, leaves a gap
    /// instead of a short card in a ragged grid.
    private static let contentHeight: CGFloat = 34 + 10 + gaugeRow + 10 + 1 + 10 + gaugeRow

    private var toners: [Supply] { vm.supplies.filter { $0.family == "TONER" } }
    /// Only trays the device measured; an unmeasurable one has no level to draw.
    private var trays: [PaperTray] {
        vm.trayVolumeDetection == false ? [] : vm.trays.filter { $0.remaining != nil }
    }
    private func counter(_ key: String) -> Int? {
        vm.counters.first { $0.domesticName == key }?.count
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(vm.about?.devFrndlName ?? vm.printer.name)
                            .font(.headline)
                        Text(vm.printer.host).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let s = vm.status?.status {
                        Text(s.replacingOccurrences(of: "_", with: " ").capitalized)
                            .font(.caption)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    }
                }

                if toners.isEmpty {
                    Text(vm.errorMessage ?? "No supply data")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack(alignment: .top, spacing: 8) {
                        RowLabel("Toner")
                        ForEach(toners) { s in
                            VStack(spacing: 3) {
                                ZStack(alignment: .bottom) {
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(Color.secondary.opacity(0.18))
                                        .frame(width: 26, height: 44)
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(SupplyFormat.colour(s))
                                        .frame(width: 26,
                                               height: max(2, 44 * CGFloat(s.remaining ?? 0) / 100))
                                }
                                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.separator))
                                Text("\(s.remaining ?? 0)%")
                                    .font(.caption2).monospacedDigit()
                            }
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            if let p = counter("PRINT_TOTAL_IMPRESSION") {
                                Text("\(p) printed").font(.caption2).foregroundStyle(.secondary)
                            }
                            if let c = counter("COPY_TOTAL_IMPRESSION") {
                                Text("\(c) copied").font(.caption2).foregroundStyle(.secondary)
                            }
                            if !vm.users.isEmpty {
                                Text("\(vm.users.count) users").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }

                    if !trays.isEmpty {
                        Divider()
                        HStack(alignment: .top, spacing: 8) {
                            RowLabel("Paper")
                            ForEach(trays) { CardTray(tray: $0) }
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: Self.contentHeight, alignment: .topLeading)
        }
        .task { await vm.connect() }
    }
}
