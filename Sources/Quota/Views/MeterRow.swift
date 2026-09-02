import SwiftUI

/// One meter: a bar counting down a real allowance, or a plain total where there is no
/// cap. Uncapped meters get no bar on purpose -- a full-width bar reads as "you are out
/// of quota", which is the opposite of what unlimited means.
struct MeterRow: View {
    let meter: UsageMeter
    /// Set on the fleet total when a printer could not be read, so the figure is a
    /// lower bound rather than a fact.
    var provisional: Bool = false

    private static let number: NumberFormatter = {
        let f = NumberFormatter(); f.numberStyle = .decimal; return f
    }()
    private func fmt(_ n: Int) -> String {
        Self.number.string(from: NSNumber(value: n)) ?? String(n)
    }

    /// Amber once most of the allowance is gone, red when it is nearly all gone.
    private var tint: Color {
        switch meter.fraction {
        case 0.95...: return .red
        case 0.80...: return .orange
        default:      return .accentColor
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Label {
                    Text(meter.label)
                } icon: {
                    Image(systemName: icon)
                        .foregroundStyle(meter.isColour ? .primary : .secondary)
                }
                .font(.callout)

                Spacer(minLength: 8)

                Group {
                    if meter.isUnlimited {
                        Text("\(fmt(meter.used))\(provisional ? "+" : "")")
                            .fontWeight(.medium)
                        + Text(" pages").foregroundStyle(.secondary)
                    } else {
                        Text("\(fmt(meter.remaining ?? 0))")
                            .fontWeight(.medium)
                        + Text(" left of \(fmt(meter.limit ?? 0))").foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
                .monospacedDigit()
            }

            if meter.isUnlimited {
                Text("No limit")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        Capsule().fill(tint)
                            .frame(width: max(0, geo.size.width * meter.fraction))
                    }
                }
                .frame(height: 5)
                .animation(.easeOut(duration: 0.25), value: meter.fraction)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(meter.label)
        .accessibilityValue(meter.isUnlimited
                            ? "\(meter.used) pages used, no limit"
                            : "\(meter.remaining ?? 0) of \(meter.limit ?? 0) remaining")
    }

    private var icon: String {
        switch meter.feature {
        case "Copy": return "doc.on.doc"
        case "Scan": return "scanner"
        default:     return "printer"
        }
    }
}
