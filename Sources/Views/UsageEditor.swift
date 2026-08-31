import SwiftUI

/// Account usage for one user on one printer: what they have used against each meter,
/// and the caps. Mirrors the device's own Account Usage panel.
struct UsageEditor: View {
    let user: DeviceUser
    @ObservedObject var vm: DeviceViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var limits: [String: String] = [:]
    @State private var unlimited: [String: Bool] = [:]
    @State private var saving = false
    @State private var confirmClear = false

    init(user: DeviceUser, vm: DeviceViewModel) {
        self.user = user
        self.vm = vm
        var l: [String: String] = [:]
        var u: [String: Bool] = [:]
        for type in UsageMeter.allTypes {
            let meter = user.usage.first { $0.type == type }
            let isUnlimited = meter?.isUnlimited ?? true
            u[type] = isUnlimited
            l[type] = isUnlimited ? "" : String(meter?.limit ?? 0)
        }
        _limits = State(initialValue: l)
        _unlimited = State(initialValue: u)
    }

    private func meter(_ type: String) -> UsageMeter? {
        user.usage.first { $0.type == type }
    }

    private var groups: [(String, [String])] {
        [("Copy", ["CopyColor", "CopyBW"]),
         ("Print", ["PrintColor", "PrintBW"]),
         ("Scan", ["ScanColor", "ScanBW"])]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Account Usage").font(.title2).bold()
                Text("\(user.displayName) · \(user.userID) on \(vm.printer.name)")
                    .font(.callout).foregroundStyle(.secondary)
            }

            if user.usage.isEmpty {
                Label("This printer reported no accounting meters for the user. Usage tracking is only populated when device accounting is enabled.",
                      systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(groups, id: \.0) { group in
                GroupBox(group.0) {
                    VStack(spacing: 8) {
                        ForEach(group.1, id: \.self) { type in
                            MeterRow(type: type,
                                     meter: meter(type),
                                     limitText: Binding(
                                        get: { limits[type] ?? "" },
                                        set: { limits[type] = $0 }),
                                     isUnlimited: Binding(
                                        get: { unlimited[type] ?? true },
                                        set: { unlimited[type] = $0 }))
                        }
                    }
                }
            }

            if let e = vm.usersError {
                Text(e).font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Reset Counters…") { confirmClear = true }
                    .disabled(saving || user.usage.isEmpty)
                if saving { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save Limits") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving)
            }
        }
        .padding(20)
        .frame(width: 520)
        .alert("Reset usage counters for \(user.displayName)?", isPresented: $confirmClear) {
            Button("Reset", role: .destructive) {
                Task { saving = true; await vm.clearUsage(user); saving = false; dismiss() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This sets the used totals back to zero on \(vm.printer.name). Limits are unchanged. It cannot be undone.")
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        var out: [String: Int] = [:]
        for type in UsageMeter.allTypes {
            if unlimited[type] ?? true {
                out[type] = UsageMeter.unlimited
            } else if let v = Int((limits[type] ?? "").trimmingCharacters(in: .whitespaces)) {
                out[type] = max(0, v)
            }
        }
        await vm.saveUsageLimits(user, limits: out)
        if vm.usersError == nil { dismiss() }
    }
}

private struct MeterRow: View {
    let type: String
    let meter: UsageMeter?
    @Binding var limitText: String
    @Binding var isUnlimited: Bool

    private var isColour: Bool { type.hasSuffix("Color") }

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 5) {
                Circle().fill(isColour ? Color.accentColor : Color.secondary)
                    .frame(width: 8, height: 8)
                Text(isColour ? "Colour" : "Black & White").frame(width: 110, alignment: .leading)
            }

            Text(meter.map { "\($0.used)" } ?? "0")
                .monospacedDigit().frame(width: 64, alignment: .trailing)
                .help("Used")

            Text("of").foregroundStyle(.secondary).font(.caption)

            TextField("limit", text: $limitText)
                .frame(width: 90)
                .monospacedDigit()
                .disabled(isUnlimited)

            Toggle("Unlimited", isOn: $isUnlimited).toggleStyle(.checkbox)

            Spacer()

            if let m = meter, !m.isUnlimited, let limit = m.limit, limit > 0 {
                ProgressView(value: m.fraction)
                    .frame(width: 70)
                    .tint(m.fraction > 0.9 ? .orange : .accentColor)
            }
        }
        .font(.callout)
    }
}
