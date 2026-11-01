import SwiftUI
import SwitcherCore

/// Ring gauge in the style of the reference app: grey track, coloured arc, big percentage in the middle.
struct UsageRingView: View {
    var percent: Double?
    var label: String
    var sublabel: String?
    var size: CGFloat = 84
    var lineWidth: CGFloat = 9
    var showRemaining = false

    private var value: Double { percent ?? 0 }
    private var displayed: Double { showRemaining ? max(0, 100 - value) : value }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().stroke(Color.secondary.opacity(0.18), lineWidth: lineWidth)
                if percent != nil {
                    Circle()
                        .trim(from: showRemaining ? CGFloat(value / 100) : 0, to: showRemaining ? 1 : CGFloat(value / 100))
                        .stroke(UsageFormat.color(for: value), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.spring(response: 0.42, dampingFraction: 0.78), value: value)
                }
                VStack(spacing: 0) {
                    Text(percent == nil ? "—" : "\(Int(displayed.rounded()))%")
                        .font(.system(size: size * 0.26, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text(percent == nil ? "none" : (showRemaining ? "left" : "used"))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(width: size, height: size)
            Text(label).font(.caption).fontWeight(.medium)
            if let sublabel {
                Text(sublabel).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(percent.map { "\(Int($0))% used" } ?? "no data")")
    }
}

/// Thin horizontal bar for per-model weekly limits and extra usage.
struct UsageBarView: View {
    var label: String
    var percent: Double
    var trailing: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(.caption)
                Spacer()
                Text("\(Int(percent.rounded()))%").font(.caption).monospacedDigit()
                if let trailing { Text(trailing).font(.caption2).foregroundStyle(.secondary).monospacedDigit() }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.18))
                    Capsule().fill(UsageFormat.color(for: percent)).frame(width: geo.size.width * CGFloat(min(100, max(0, percent)) / 100))
                }
            }
            .frame(height: 6)
        }
    }
}
