import Cocoa

let defaultPalette: [NSColor] = [
    NSColor(hue: 0.74, saturation: 0.30, brightness: 0.85, alpha: 1),   // lavender
    NSColor(hue: 0.95, saturation: 0.28, brightness: 0.88, alpha: 1),   // rose
    NSColor(hue: 0.08, saturation: 0.30, brightness: 0.90, alpha: 1)    // peach
]

enum GlowMode: Int, CaseIterable {
    case edges, dock, both, off
    var title: String { ["Screen edges & corners", "Dock aura", "Both", "Off"][rawValue] }
    var showsEdges: Bool { self == .edges || self == .both }
    var showsDock: Bool { self == .dock || self == .both }
}

enum GlowIntensity: Int, CaseIterable {
    case subtle, medium, bold
    var title: String { ["Subtle", "Medium", "Bold"][rawValue] }
    var alpha: CGFloat { [0.30, 0.48, 0.68][rawValue] }
    var thickness: CGFloat { [55, 85, 125][rawValue] }
    var aura: CGFloat { [50, 80, 115][rawValue] }
}

enum DockEdge {
    case bottom, left, right
    static func current() -> DockEdge {
        let o = UserDefaults(suiteName: "com.apple.dock")?.string(forKey: "orientation") ?? "bottom"
        switch o {
        case "left": return .left
        case "right": return .right
        default: return .bottom
        }
    }
}

func dockThickness(on screen: NSScreen, edge: DockEdge) -> CGFloat {
    let f = screen.frame, v = screen.visibleFrame
    let inset: CGFloat
    switch edge {
    case .bottom: inset = v.minY - f.minY
    case .left: inset = v.minX - f.minX
    case .right: inset = f.maxX - v.maxX
    }
    return inset > 20 ? inset : 70
}

extension NSImage {
    func palette(_ n: Int = 3) -> [NSColor] {
        let side = 16
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return defaultPalette }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()

        var bins = Array(repeating: (w: CGFloat(0), r: CGFloat(0), g: CGFloat(0), b: CGFloat(0)), count: 12)
        for x in 0..<side {
            for y in 0..<side {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let s = c.saturationComponent, v = c.brightnessComponent
                guard s > 0.18, v > 0.18 else { continue }
                let w = s * s * v
                let k = min(11, Int(c.hueComponent * 12))
                bins[k].w += w
                bins[k].r += c.redComponent * w
                bins[k].g += c.greenComponent * w
                bins[k].b += c.blueComponent * w
            }
        }
        let top = bins.filter { $0.w > 0.05 }.sorted { $0.w > $1.w }.prefix(n)
        var out: [NSColor] = top.map { b in
            let raw = NSColor(deviceRed: b.r / b.w, green: b.g / b.w, blue: b.b / b.w, alpha: 1)
            return NSColor(hue: raw.hueComponent,
                           saturation: min(1, max(0.5, raw.saturationComponent * 1.15)),
                           brightness: min(1, max(0.75, raw.brightnessComponent)),
                           alpha: 1)
        }
        if out.isEmpty { out = defaultPalette }
        while out.count < n, let base = out.first {
            let h = (base.hueComponent + 0.07 * CGFloat(out.count)).truncatingRemainder(dividingBy: 1)
            out.append(NSColor(hue: h, saturation: base.saturationComponent,
                               brightness: base.brightnessComponent, alpha: 1))
        }
        return out
    }
}

// Screen edge glow + dock aura

final class AmbientView: NSView {
    private let presence = CALayer()   // fades with play state
    private let beatLayer = CALayer()  // follows the music
    private let breath = CALayer()     // slow breathing loop
    private var edgeLayers: [CAGradientLayer] = []
    private var cornerLayers: [CAGradientLayer] = []
    private var blobLayers: [CAGradientLayer] = []

    var mode: GlowMode = .both
    var intensity: GlowIntensity = .subtle
    var dockEdge: DockEdge = .bottom
    var dockThickness: CGFloat = 70
    var palette: [NSColor] = defaultPalette
    var offset = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer = CALayer()
        wantsLayer = true
        layer?.addSublayer(presence)
        presence.addSublayer(beatLayer)
        beatLayer.addSublayer(breath)
        presence.opacity = 0

        let b = CABasicAnimation(keyPath: "opacity")
        b.fromValue = 0.6
        b.toValue = 1.0
        b.duration = 3.8
        b.autoreverses = true
        b.repeatCount = .infinity
        b.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        breath.add(b, forKey: "breath")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func rebuild() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        breath.sublayers?.forEach { $0.removeFromSuperlayer() }
        edgeLayers = []; cornerLayers = []; blobLayers = []

        let b = bounds
        presence.frame = b
        beatLayer.frame = b
        breath.frame = b
        let t = intensity.thickness

        if mode.showsEdges {
            let specs: [(CGRect, CGPoint, CGPoint)] = [
                (CGRect(x: 0, y: 0, width: b.width, height: t), CGPoint(x: 0.5, y: 0), CGPoint(x: 0.5, y: 1)),
                (CGRect(x: 0, y: b.height - t, width: b.width, height: t), CGPoint(x: 0.5, y: 1), CGPoint(x: 0.5, y: 0)),
                (CGRect(x: 0, y: 0, width: t, height: b.height), CGPoint(x: 0, y: 0.5), CGPoint(x: 1, y: 0.5)),
                (CGRect(x: b.width - t, y: 0, width: t, height: b.height), CGPoint(x: 1, y: 0.5), CGPoint(x: 0, y: 0.5))
            ]
            for (f, s, e) in specs {
                let g = CAGradientLayer()
                g.frame = f
                g.startPoint = s
                g.endPoint = e
                g.locations = [0, 0.35, 1]
                breath.addSublayer(g)
                edgeLayers.append(g)
            }
            let r = t * 3
            let corners = [CGPoint(x: 0, y: 0), CGPoint(x: b.width, y: 0),
                           CGPoint(x: 0, y: b.height), CGPoint(x: b.width, y: b.height)]
            for p in corners {
                let g = CAGradientLayer()
                g.type = .radial
                g.frame = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
                g.startPoint = CGPoint(x: 0.5, y: 0.5)
                g.endPoint = CGPoint(x: 1, y: 1)
                g.locations = [0, 0.35, 1]
                breath.addSublayer(g)
                cornerLayers.append(g)
            }
        }

        if mode.showsDock {
            let along: CGFloat = dockEdge == .bottom ? b.width : b.height
            let blobAlong = along * 0.42
            let blobAcross = (dockThickness + intensity.aura) * 2
            let across = dockThickness * 0.35
            let fractions: [CGFloat] = [0.32, 0.5, 0.68]
            let drift: [CGFloat] = [0.10, 0.08, 0.11]
            let durations: [Double] = [11, 14, 9]

            func point(_ a: CGFloat) -> CGPoint {
                switch dockEdge {
                case .bottom: return CGPoint(x: a, y: across)
                case .left: return CGPoint(x: across, y: a)
                case .right: return CGPoint(x: b.width - across, y: a)
                }
            }

            for i in 0..<3 {
                let g = CAGradientLayer()
                g.type = .radial
                g.startPoint = CGPoint(x: 0.5, y: 0.5)
                g.endPoint = CGPoint(x: 1, y: 1)
                g.locations = [0, 0.35, 1]
                let size = dockEdge == .bottom
                    ? CGSize(width: blobAlong, height: blobAcross)
                    : CGSize(width: blobAcross, height: blobAlong)
                g.bounds = CGRect(origin: .zero, size: size)
                g.position = point(along * fractions[i])

                let anim = CABasicAnimation(keyPath: "position")
                anim.fromValue = NSValue(point: point(along * (fractions[i] - drift[i])))
                anim.toValue = NSValue(point: point(along * (fractions[i] + drift[i])))
                anim.duration = durations[i]
                anim.autoreverses = true
                anim.repeatCount = .infinity
                anim.timeOffset = durations[i] * 0.5
                anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                g.add(anim, forKey: "drift")

                breath.addSublayer(g)
                blobLayers.append(g)
            }
        }

        applyColors(duration: 0)
        CATransaction.commit()
    }

    func applyColors(duration: Double) {
        let p = palette.isEmpty ? defaultPalette : palette
        let a = intensity.alpha
        func stops(_ c: NSColor, _ alpha: CGFloat) -> [CGColor] {
            [c.withAlphaComponent(alpha).cgColor,
             c.withAlphaComponent(alpha * 0.35).cgColor,
             c.withAlphaComponent(0).cgColor]
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        if duration == 0 { CATransaction.setDisableActions(true) }
        for (i, g) in edgeLayers.enumerated() { g.colors = stops(p[(i + offset) % p.count], a) }
        for (i, g) in cornerLayers.enumerated() { g.colors = stops(p[(i + offset + 1) % p.count], a * 0.9) }
        for (i, g) in blobLayers.enumerated() { g.colors = stops(p[(i + offset) % p.count], min(1, a * 1.25)) }
        CATransaction.commit()
    }

    func setPlaying(_ on: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(on ? 1.5 : 2.5)
        presence.opacity = on ? 1 : 0
        CATransaction.commit()
    }

    func setBeat(_ v: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        beatLayer.opacity = Float(0.5 + 0.5 * min(1, max(0, v)))
        CATransaction.commit()
    }
}

final class Overlay {
    private var windows: [NSWindow] = []
    private var views: [AmbientView] = []
    private(set) var palette = defaultPalette
    private var playing = false
    private var offset = 0

    var mode: GlowMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "glowMode"); rebuild() }
    }
    var intensity: GlowIntensity {
        didSet { UserDefaults.standard.set(intensity.rawValue, forKey: "glowIntensity"); rebuild() }
    }

    init() {
        let d = UserDefaults.standard
        mode = GlowMode(rawValue: (d.object(forKey: "glowMode") as? Int) ?? GlowMode.edges.rawValue) ?? .edges
        intensity = GlowIntensity(rawValue: d.integer(forKey: "glowIntensity")) ?? .subtle
    }

    func rebuild() {
        windows.forEach { $0.orderOut(nil) }
        windows = []
        views = []
        guard mode != .off else { return }

        let edge = DockEdge.current()
        for screen in NSScreen.screens {
            let w = NSWindow(contentRect: screen.frame, styleMask: .borderless,
                             backing: .buffered, defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.ignoresMouseEvents = true
            w.isReleasedWhenClosed = false
            w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) - 1)
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

            let v = AmbientView(frame: NSRect(origin: .zero, size: screen.frame.size))
            v.mode = mode
            v.intensity = intensity
            v.dockEdge = edge
            v.dockThickness = dockThickness(on: screen, edge: edge)
            v.palette = palette
            v.offset = offset
            w.contentView = v
            w.setFrame(screen.frame, display: false)
            v.rebuild()
            w.orderFrontRegardless()
            v.setPlaying(playing)

            windows.append(w)
            views.append(v)
        }
    }

    func setPalette(_ p: [NSColor]) {
        palette = p
        views.forEach { $0.palette = p; $0.applyColors(duration: 2.5) }
    }

    func setPlaying(_ on: Bool) {
        guard on != playing else { return }
        playing = on
        views.forEach { $0.setPlaying(on) }
    }

    func setBeat(_ v: CGFloat) {
        guard playing else { return }
        views.forEach { $0.setBeat(v) }
    }

    func flow() {
        guard playing else { return }
        offset += 1
        views.forEach { $0.offset = offset; $0.applyColors(duration: 4) }
    }
}
