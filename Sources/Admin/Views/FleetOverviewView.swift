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

private struct PrinterCard: View {
    @ObservedObject var vm: DeviceViewModel

    private var toners: [Supply] { vm.supplies.filter { $0.family == "TONER" } }
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
                    HStack(spacing: 8) {
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
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await vm.connect() }
    }
}
