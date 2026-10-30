import AppKit

/// Draws the menu bar glyph: a ring for the active Claude account (and a thin outer ring for Codex).
enum MenuBarIconRenderer {
    static func image(claudePercent: Double?, codexPercent: Double?) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let center = NSPoint(x: rect.midX, y: rect.midY)
            func ring(radius: CGFloat, width: CGFloat, percent: Double?, dashed: Bool) {
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
            ring(radius: 7.5, width: 1.2, percent: codexPercent, dashed: true)
            ring(radius: 5, width: 2.2, percent: claudePercent, dashed: false)
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

    static func color(for percent: Double) -> NSColor {
        if percent >= 90 { return .systemRed }
        if percent >= 70 { return .systemOrange }
        return .systemGreen
    }
}
