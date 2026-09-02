import SwiftUI

/// The Copy / Print / Scan limit rows, shared by the editor for an existing user and by
/// the Add User sheet. Kept in one place so the two cannot drift into showing different
/// meters or grouping them differently.
///
/// `meter` supplies the device's recorded counters where they exist. A user being
/// created has none, so the caller omits it and the rows show limits alone.
struct UsageLimitsFields: View {
    @Binding var limits: [String: String]
    @Binding var unlimited: [String: Bool]
    var meter: (String) -> UsageMeter? = { _ in nil }

    private var groups: [(String, [String])] {
        [("Copy", ["CopyColor", "CopyBW"]),
         ("Print", ["PrintColor", "PrintBW"]),
         ("Scan", ["ScanColor", "ScanBW"])]
    }

    var body: some View {
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

            if let meter {
                Text("\(meter.used)")
                    .monospacedDigit().frame(width: 64, alignment: .trailing)
                    .help("Used")
                Text("of").foregroundStyle(.secondary).font(.caption)
            }

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
