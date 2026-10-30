import AppKit
import SwitcherCore

/// One account in the menu bar label.
struct MenuBarSegment: Equatable {
    var label: String
    var percent: Double?
    var isActive: Bool
    var provider: Provider
}

/// Draws the menu bar glyph. Two styles:
/// * `image(segments:)` — every account as `● WK 12%` with threshold colors (rendered as a non-template image
///   so the colors survive light and dark menu bars),
/// * `image(claudePercent:codexPercent:)` — the original single ring for "active accounts only".
enum MenuBarIconRenderer {
    static let height: CGFloat = 18

    static func color(for percent: Double) -> NSColor {
        if percent >= 90 { return .systemRed }
        if percent >= 70 { return .systemOrange }
        return .systemGreen
    }

    private static func drawRing(center: NSPoint, radius: CGFloat, width: CGFloat, percent: Double?, dashed: Bool = false) {
        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = width
        NSColor.labelColor.withAlphaComponent(0.25).setStroke()
        if dashed { track.setLineDash([2, 1.5], count: 2, phase: 0) }
        track.stroke()
        guard let percent, percent > 0 else { return }
        let progress = NSBezierPath()
        let sweep = CGFloat(min(100, max(0, percent)) / 100 * 360)
        progress.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - sweep, clockwise: true)
        progress.lineWidth = width
        progress.lineCapStyle = percent >= 100 ? .butt : .round
        color(for: percent).setStroke()
        progress.stroke()
    }

    /// All accounts: short label + usage per account, dot before the active one, optional mini ring.
    static func image(segments: [MenuBarSegment], compact: Bool, showRings: Bool) -> NSImage {
        guard !segments.isEmpty else { return image(claudePercent: nil, codexPercent: nil) }
        let labelFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let gap: CGFloat = compact ? 6 : 9
        let ringSize: CGFloat = 10
        let rings = showRings && !compact

        struct Piece {
            let label: NSAttributedString
            let value: NSAttributedString
            let width: CGFloat
            let segment: MenuBarSegment
        }
        var pieces: [Piece] = []
        for segment in segments {
            let label = NSAttributedString(string: segment.label, attributes: [.font: labelFont, .foregroundColor: NSColor.labelColor])
            let valueText: String
            if let p = segment.percent { valueText = compact ? "\(Int(p.rounded()))" : "\(Int(p.rounded()))%" } else { valueText = "–" }
            let valueColor = segment.percent.map(color(for:)) ?? NSColor.secondaryLabelColor
            let value = NSAttributedString(string: valueText, attributes: [.font: valueFont, .foregroundColor: valueColor])
            var width = label.size().width + 2 + value.size().width
            if rings { width += ringSize + 3 }
            if segment.isActive { width += 7 }
            pieces.append(Piece(label: label, value: value, width: width, segment: segment))
        }
        let totalWidth = ceil(pieces.reduce(0) { $0 + $1.width } + gap * CGFloat(pieces.count - 1) + 2)
        let image = NSImage(size: NSSize(width: max(18, totalWidth), height: height), flipped: false) { rect in
            var x: CGFloat = 1
            let midY = rect.midY
            for piece in pieces {
                if piece.segment.isActive {
                    let dot = NSBezierPath(ovalIn: NSRect(x: x, y: midY - 2, width: 4, height: 4))
                    NSColor.labelColor.setFill()
                    dot.fill()
                    x += 7
                }
                if rings {
                    drawRing(center: NSPoint(x: x + ringSize / 2, y: midY), radius: ringSize / 2 - 1, width: 2, percent: piece.segment.percent)
                    x += ringSize + 3
                }
                let labelSize = piece.label.size()
                piece.label.draw(at: NSPoint(x: x, y: midY - labelSize.height / 2))
                x += labelSize.width + 2
                let valueSize = piece.value.size()
                piece.value.draw(at: NSPoint(x: x, y: midY - valueSize.height / 2))
                x += valueSize.width + gap
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Active accounts only: a ring for Claude (inner) and a thin dashed ring for Codex (outer).
    static func image(claudePercent: Double?, codexPercent: Double?) -> NSImage {
        let size = NSSize(width: 18, height: height)
        let image = NSImage(size: size, flipped: false) { rect in
            let center = NSPoint(x: rect.midX, y: rect.midY)
            drawRing(center: center, radius: 7.5, width: 1.2, percent: codexPercent, dashed: true)
            drawRing(center: center, radius: 5, width: 2.2, percent: claudePercent)
            if claudePercent == nil && codexPercent == nil {
                let dot = NSBezierPath(ovalIn: NSRect(x: center.x - 1.5, y: center.y - 1.5, width: 3, height: 3))
                NSColor.labelColor.setFill()
                dot.fill()
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}
