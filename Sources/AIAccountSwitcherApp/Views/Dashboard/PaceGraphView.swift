import SwiftUI
import SwitcherCore

/// Pace graph: x = share of the window elapsed, y = quota used. The dotted diagonal is "on pace";
/// points above it mean the account is burning faster than the window refills.
struct PaceGraphView: View {
    var windows: [UsageWindow]
    var now: Date
    var height: CGFloat = 110

    private struct Point: Identifiable {
        let id: String
        let x: Double
        let y: Double
        let label: String
    }

    private var points: [Point] {
        windows.compactMap { w in
            guard let x = w.elapsedRatio(now: now) else { return nil }
            return Point(id: w.id, x: x, y: w.usedPercent / 100, label: w.label)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Canvas { context, size in
                let inset: CGFloat = 8
                let rect = CGRect(x: inset, y: inset, width: size.width - 2 * inset, height: size.height - 2 * inset)
                for q in [0.25, 0.5, 0.75, 1.0] {
                    let y = rect.maxY - rect.height * q
                    var p = Path()
                    p.move(to: CGPoint(x: rect.minX, y: y)); p.addLine(to: CGPoint(x: rect.maxX, y: y))
                    context.stroke(p, with: .color(.secondary.opacity(0.15)), lineWidth: 0.5)
                    let x = rect.minX + rect.width * q
                    var v = Path()
                    v.move(to: CGPoint(x: x, y: rect.minY)); v.addLine(to: CGPoint(x: x, y: rect.maxY))
                    context.stroke(v, with: .color(.secondary.opacity(0.15)), lineWidth: 0.5)
                }
                var diag = Path()
                diag.move(to: CGPoint(x: rect.minX, y: rect.maxY)); diag.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
                context.stroke(diag, with: .color(.secondary.opacity(0.5)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [0.01, 4]))
                for pt in points {
                    let c = CGPoint(x: rect.minX + rect.width * pt.x, y: rect.maxY - rect.height * pt.y)
                    let dot = Path(ellipseIn: CGRect(x: c.x - 6, y: c.y - 6, width: 12, height: 12))
                    context.fill(dot, with: .color(UsageFormat.color(for: pt.y * 100)))
                    context.stroke(dot, with: .color(Color(nsColor: .windowBackgroundColor)), lineWidth: 2)
                    context.draw(Text(pt.label).font(.system(size: 9)).foregroundStyle(.secondary), at: CGPoint(x: c.x, y: c.y - 14))
                }
            }
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
            HStack {
                Text("window start").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text("above the line = ahead of pace").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text("reset").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
