import SwiftUI

/// The menu bar dropdown: fleet status at a glance, without opening the app.
struct MenuBarPanel: View {
    @EnvironmentObject var fleet: Fleet
    @Environment(\.openWindow) private var openWindow

    private var devices: [DeviceViewModel] { fleet.ordered() }

    private var alerts: [(printer: String, supply: Supply)] {
        devices.flatMap { vm in vm.suppliesNeedingAttention.map { (vm.printer.name, $0) } }
            .sorted { ($0.supply.remaining ?? 0) < ($1.supply.remaining ?? 0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Printers").font(.headline)
                Spacer()
                if fleet.isLoadingAll {
                    ProgressView().controlSize(.small)
                } else {
                    Button { Task { await fleet.refreshAll() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh all printers")
                }
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)

            if !alerts.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(alerts.indices, id: \.self) { i in
                        let a = alerts[i]
                        HStack(spacing: 6) {
                            Image(systemName: a.supply.isSpent
                                  ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(a.supply.isSpent ? Color.red : Color.orange)
                            Text(a.printer).bold()
                            Text(SupplyFormat.title(a.supply))
                            Spacer()
                            Text(a.supply.isSpent ? "replace" : "\(a.supply.remaining ?? 0)%")
                                .foregroundStyle(.secondary).monospacedDigit()
                        }
                        .font(.caption)
                    }
                }
                .padding(.horizontal, 14).padding(.bottom, 8)
                Divider()
            }

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(devices, id: \.printer.id) { vm in
                        MenuBarPrinterRow(vm: vm)
                        Divider()
                    }
                }
            }
            .frame(maxHeight: 260)

            if devices.isEmpty {
                Text("No printers added yet.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 14).padding(.vertical, 10)
            }

            HStack {
                Button("Open Manager") {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "main")
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
        .frame(width: 330)
        .task { await fleet.connectAll() }
    }
}

private struct MenuBarPrinterRow: View {
    @ObservedObject var vm: DeviceViewModel

    private var toners: [Supply] { vm.supplies.filter { $0.family == "TONER" } }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(vm.about?.devFrndlName ?? vm.printer.name)
                    .font(.callout).fontWeight(.medium)
                Spacer()
                Text(vm.status?.status.replacingOccurrences(of: "_", with: " ").capitalized ?? "—")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if toners.isEmpty {
                Text(vm.errorMessage ?? "no data")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            } else {
                HStack(spacing: 5) {
                    ForEach(toners) { s in
                        HStack(spacing: 3) {
                            Circle().fill(SupplyFormat.colour(s)).frame(width: 7, height: 7)
                            Text("\(s.remaining ?? 0)%")
                                .font(.caption2).monospacedDigit()
                                .foregroundStyle((s.remaining ?? 100) <= 15 ? Color.orange : Color.secondary)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
    }
}
