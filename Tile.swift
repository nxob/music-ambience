import Cocoa

// The spinning record in the dock icon

final class TileView: NSView {
    var artwork: NSImage?
    var accent = defaultPalette[0]
    var angle: CGFloat = 0
    var glow: CGFloat = 0
    var progress: CGFloat = 0
    var pulse: CGFloat = 0

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let s = min(bounds.width, bounds.height)
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        let tile = bounds.insetBy(dx: s * 0.09, dy: s * 0.09)
        let corner = tile.width * 0.225
        let deep = accent.blended(withFraction: 0.82, of: .black) ?? .black
        let mid = accent.blended(withFraction: 0.55, of: .black) ?? .darkGray

        ctx.saveGState()
        NSBezierPath(roundedRect: tile, xRadius: corner, yRadius: corner).addClip()
        NSGradient(colors: [mid, deep])?.draw(in: tile, angle: -60)
        let breath = 0.75 + 0.25 * sin(pulse)
        let glowAlpha = 0.15 + 0.55 * glow * breath
        NSGradient(colors: [accent.withAlphaComponent(glowAlpha), accent.withAlphaComponent(0)])?
            .draw(fromCenter: c, radius: 0, toCenter: c, radius: s * 0.48, options: [])
        ctx.restoreGState()

        let discR = s * 0.30
        let discRect = NSRect(x: c.x - discR, y: c.y - discR, width: discR * 2, height: discR * 2)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.04,
                      color: NSColor.black.withAlphaComponent(0.6).cgColor)
        NSColor(white: 0.06, alpha: 1).setFill()
        NSBezierPath(ovalIn: discRect).fill()
        ctx.restoreGState()

        NSColor(white: 1, alpha: 0.06).setStroke()
        for i in 0..<6 {
            let r = discR * (0.55 + CGFloat(i) * 0.075)
            let groove = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            groove.lineWidth = max(0.5, s * 0.004)
            groove.stroke()
        }

        ctx.saveGState()
        NSBezierPath(ovalIn: discRect).addClip()
        NSGradient(colors: [.clear, NSColor(white: 1, alpha: 0.14), .clear,
                            NSColor(white: 1, alpha: 0.08), .clear])?.draw(in: discRect, angle: 45)
        ctx.restoreGState()

        let labelR = discR * 0.46
        ctx.saveGState()
        ctx.translateBy(x: c.x, y: c.y)
        ctx.rotate(by: -angle)
        let labelRect = NSRect(x: -labelR, y: -labelR, width: labelR * 2, height: labelR * 2)
        NSBezierPath(ovalIn: labelRect).addClip()
        if let art = artwork {
            art.draw(in: labelRect, from: .zero, operation: .sourceOver, fraction: 1)
        } else {
            NSGradient(colors: [accent, deep])?.draw(in: labelRect, angle: 90)
            NSColor(white: 1, alpha: 0.5).setFill()
            NSBezierPath(rect: NSRect(x: -labelR * 0.06, y: labelR * 0.45,
                                      width: labelR * 0.12, height: labelR * 0.35)).fill()
        }
        ctx.restoreGState()

        let hole = s * 0.018
        NSColor(white: 0.08, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: c.x - hole, y: c.y - hole, width: hole * 2, height: hole * 2)).fill()

        let ringR = discR + s * 0.045
        let lineW = s * 0.022
        let ringBase = NSBezierPath(ovalIn: NSRect(x: c.x - ringR, y: c.y - ringR, width: ringR * 2, height: ringR * 2))
        ringBase.lineWidth = lineW
        NSColor(white: 1, alpha: 0.10).setStroke()
        ringBase.stroke()
        if progress > 0.001 {
            let arc = NSBezierPath()
            arc.appendArc(withCenter: c, radius: ringR, startAngle: 90,
                          endAngle: 90 - 360 * progress, clockwise: true)
            arc.lineWidth = lineW
            arc.lineCapStyle = .round
            let ringColor = accent.blended(withFraction: 0.25, of: .white) ?? accent
            ringColor.withAlphaComponent(0.5 + 0.5 * glow).setStroke()
            arc.stroke()
        }
    }
}
