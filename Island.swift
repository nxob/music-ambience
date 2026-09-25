import Cocoa
import CoreImage

// A small glass card that floats above the dock while music plays.
// Idle: artwork, title, artist and a slow waveform. Hover: controls and progress drift in.

private func approach(_ x: inout CGFloat, _ target: CGFloat, rate: CGFloat, dt: CGFloat) {
    x += (target - x) * (1 - exp(-rate * dt))
}

private func roundedMask(_ radius: CGFloat) -> NSImage {
    let edge = radius * 2 + 1
    let img = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { r in
        NSColor.black.setFill()
        NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
        return true
    }
    img.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
    img.resizingMode = .stretch
    return img
}

final class IslandHostView: NSView {
    var onControl: ((String) -> Void)?
    var onOpen: (() -> Void)?
    var controlAt: ((NSPoint) -> String?)?
    var isOnCard: ((NSPoint) -> Bool)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let c = controlAt?(p) {
            onControl?(c)
        } else if isOnCard?(p) == true {
            onOpen?()
        }
    }
}

final class IslandController {
    // Geometry
    private static let panelSize = NSSize(width: 480, height: 230)
    private static let cardSize = CGSize(width: 336, height: 72)
    private static let cardCenter = CGPoint(x: 240, y: 118)
    private static let radius: CGFloat = 24
    private static let controlCenters: [(String, CGPoint)] = [
        ("previous track", CGPoint(x: 260, y: 36)),
        ("playpause", CGPoint(x: 286, y: 36)),
        ("next track", CGPoint(x: 312, y: 36))
    ]
    private static let ciContext = CIContext()

    let panel: NSPanel
    let view: IslandHostView
    private let glowHost = NSView()
    private let effect = NSVisualEffectView()
    private let scale = NSScreen.main?.backingScaleFactor ?? 2

    // Layers behind the glass
    private let glowRoot = CALayer()
    private let glowBreath = CALayer()
    private let blobA = CAGradientLayer()
    private let blobB = CAGradientLayer()
    private let shadowLayer = CALayer()

    // Layers on the glass
    private let card = CALayer()
    private let tint = CALayer()
    private let scrim = CALayer()
    private let highlight = CAGradientLayer()
    private let artHolder = CALayer()
    private let artLayer = CALayer()
    private let titleLayer = CATextLayer()
    private let artistLayer = CATextLayer()
    private let waveHolder = CALayer()
    private let waveA = CAShapeLayer()
    private let waveB = CAShapeLayer()
    private let controlsHolder = CALayer()
    private var controlLayers: [String: CALayer] = [:]
    private let progressHolder = CALayer()
    private let progressFill = CAGradientLayer()

    // Motion state
    private var vis: CGFloat = 0
    private var hover: CGFloat = 0
    private var dim: CGFloat = 1
    private var level: CGFloat = 0
    private var phaseA: CGFloat = 0
    private var phaseB: CGFloat = 0
    private var clock: CGFloat = 0
    private var parallax = CGPoint.zero
    private var controlHover: [String: CGFloat] = [:]
    private var peaks: [Float] = [0.05, 0.05, 0.05]
    private var lastEffectFrame = NSRect.zero
    private var asleep = false

    // Song state
    private var shownKey = ""
    private var changeStarted: TimeInterval?
    private var appliedArtKey = ""
    private var readyKey = ""
    private var readyArt: NSImage?
    private var readyPalette: [NSColor] = defaultPalette
    private var pausedSince: Date?
    private var shownPlaying: Bool?

    var track: Track?
    var position: Double = 0
    var levels: AudioLevels?
    var audioLive = false
    private(set) var beat: CGFloat = 0

    var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "islandOn")
            refreshVisibility()
        }
    }

    init() {
        let size = IslandController.panelSize
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        view = IslandHostView(frame: NSRect(origin: .zero, size: size))
        enabled = UserDefaults.standard.object(forKey: "islandOn") as? Bool ?? true
        build()
    }

    // MARK: Build

    private func build() {
        let size = IslandController.panelSize
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        panel.contentView = root

        // 1. Soft colour glow and shadow, behind everything
        glowHost.frame = root.bounds
        glowHost.layer = CALayer()
        glowHost.wantsLayer = true
        root.addSubview(glowHost)
        buildGlow(in: glowHost.layer!)

        // 2. Real macOS glass
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.appearance = NSAppearance(named: .darkAqua)
        effect.maskImage = roundedMask(IslandController.radius)
        effect.alphaValue = 0
        root.addSubview(effect)

        // 3. Everything that sits on the glass
        view.frame = root.bounds
        view.layer = CALayer()
        view.wantsLayer = true
        view.layerUsesCoreImageFilters = true
        root.addSubview(view)
        buildCard(in: view.layer!)

        view.controlAt = { [weak self] p in self?.control(at: p) }
        view.isOnCard = { [weak self] p in
            guard let self = self else { return false }
            let l = self.local(p)
            return l.x >= 0 && l.y >= 0 && l.x <= IslandController.cardSize.width && l.y <= IslandController.cardSize.height
        }

        applyPalette(defaultPalette, duration: 0)
        setVisibleLayers(0)
    }

    private func buildGlow(in root: CALayer) {
        let c = IslandController.cardCenter
        let cs = IslandController.cardSize

        glowRoot.frame = root.bounds
        glowBreath.frame = root.bounds
        root.addSublayer(glowRoot)
        glowRoot.addSublayer(glowBreath)

        for (blob, size, pos, drift, dur) in [
            (blobA, CGSize(width: 300, height: 170), CGPoint(x: c.x - 80, y: c.y), CGSize(width: 14, height: 6), 13.0),
            (blobB, CGSize(width: 280, height: 150), CGPoint(x: c.x + 90, y: c.y + 4), CGSize(width: -12, height: 5), 17.0)
        ] {
            blob.type = .radial
            blob.startPoint = CGPoint(x: 0.5, y: 0.5)
            blob.endPoint = CGPoint(x: 1, y: 1)
            blob.locations = [0, 0.45, 1]
            blob.bounds = CGRect(origin: .zero, size: size)
            blob.position = pos
            let a = CABasicAnimation(keyPath: "position")
            a.fromValue = NSValue(point: CGPoint(x: pos.x - drift.width, y: pos.y - drift.height))
            a.toValue = NSValue(point: CGPoint(x: pos.x + drift.width, y: pos.y + drift.height))
            a.duration = dur
            a.autoreverses = true
            a.repeatCount = .infinity
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            blob.add(a, forKey: "drift")
            glowBreath.addSublayer(blob)
        }

        let breathe = CABasicAnimation(keyPath: "opacity")
        breathe.fromValue = 0.55
        breathe.toValue = 1.0
        breathe.duration = 7
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        glowBreath.add(breathe, forKey: "breathe")

        shadowLayer.bounds = CGRect(origin: .zero, size: cs)
        shadowLayer.position = c
        shadowLayer.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: cs),
                                        cornerWidth: IslandController.radius,
                                        cornerHeight: IslandController.radius, transform: nil)
        shadowLayer.shadowColor = NSColor.black.cgColor
        shadowLayer.shadowOpacity = 0.45
        shadowLayer.shadowRadius = 30
        shadowLayer.shadowOffset = CGSize(width: 0, height: -14)
        root.addSublayer(shadowLayer)
    }

    private func buildCard(in root: CALayer) {
        let cs = IslandController.cardSize
        let b = CGRect(origin: .zero, size: cs)

        card.bounds = b
        card.position = IslandController.cardCenter
        card.cornerRadius = IslandController.radius
        card.masksToBounds = true
        card.borderWidth = 0.5
        card.borderColor = NSColor(white: 1, alpha: 0.10).cgColor
        root.addSublayer(card)

        // Blurred artwork washing through the glass
        tint.frame = b.insetBy(dx: -20, dy: -20)
        tint.contentsGravity = .resizeAspectFill
        tint.opacity = 0.5
        card.addSublayer(tint)

        scrim.frame = b
        scrim.backgroundColor = NSColor(white: 0, alpha: 0.22).cgColor
        card.addSublayer(scrim)

        // Soft light catching the top edge
        highlight.frame = b
        highlight.colors = [NSColor(white: 1, alpha: 0.10).cgColor, NSColor(white: 1, alpha: 0).cgColor]
        highlight.startPoint = CGPoint(x: 0.5, y: 1)
        highlight.endPoint = CGPoint(x: 0.5, y: 0.5)
        card.addSublayer(highlight)

        // Artwork
        artHolder.bounds = CGRect(x: 0, y: 0, width: 40, height: 40)
        artHolder.position = CGPoint(x: 36, y: 36)
        artHolder.shadowColor = NSColor.black.cgColor
        artHolder.shadowOpacity = 0.35
        artHolder.shadowRadius = 6
        artHolder.shadowOffset = CGSize(width: 0, height: -2)
        artHolder.shadowPath = CGPath(roundedRect: artHolder.bounds, cornerWidth: 10, cornerHeight: 10, transform: nil)
        card.addSublayer(artHolder)

        artLayer.frame = artHolder.bounds
        artLayer.cornerRadius = 10
        artLayer.masksToBounds = true
        artLayer.contentsGravity = .resizeAspectFill
        artLayer.backgroundColor = NSColor(white: 1, alpha: 0.06).cgColor
        artHolder.addSublayer(artLayer)

        // Text
        configureText(titleLayer, frame: CGRect(x: 68, y: 37, width: 172, height: 20),
                      font: NSFont.systemFont(ofSize: 15.5, weight: .medium), size: 15.5, alpha: 0.9)
        configureText(artistLayer, frame: CGRect(x: 68, y: 20, width: 172, height: 15),
                      font: NSFont.systemFont(ofSize: 11.5, weight: .regular), size: 11.5, alpha: 0.5)
        card.addSublayer(titleLayer)
        card.addSublayer(artistLayer)

        // Waveform
        waveHolder.frame = CGRect(x: 266, y: 27, width: 52, height: 18)
        for (w, width) in [(waveB, CGFloat(1.0)), (waveA, CGFloat(1.3))] {
            w.frame = waveHolder.bounds
            w.fillColor = nil
            w.lineWidth = width
            w.lineCap = .round
            w.lineJoin = .round
            w.contentsScale = scale
            waveHolder.addSublayer(w)
        }
        waveHolder.filters = blurFilters()
        card.addSublayer(waveHolder)

        // Controls, hidden until hover
        controlsHolder.frame = CGRect(x: 244, y: 20, width: 86, height: 32)
        controlsHolder.filters = blurFilters()
        controlsHolder.opacity = 0
        for (name, center) in IslandController.controlCenters {
            let l = CALayer()
            l.contentsScale = scale
            l.contentsGravity = .resizeAspect
            l.position = CGPoint(x: center.x - controlsHolder.frame.minX, y: center.y - controlsHolder.frame.minY)
            setSymbol(l, name: symbolName(for: name, playing: true), fade: 0)
            controlsHolder.addSublayer(l)
            controlLayers[name] = l
            controlHover[name] = 0
        }
        card.addSublayer(controlsHolder)

        // Hairline progress, hidden until hover
        progressHolder.frame = CGRect(x: 22, y: 7, width: 292, height: 1.5)
        progressHolder.opacity = 0
        let trackLine = CALayer()
        trackLine.frame = progressHolder.bounds
        trackLine.cornerRadius = 0.75
        trackLine.backgroundColor = NSColor(white: 1, alpha: 0.10).cgColor
        progressHolder.addSublayer(trackLine)
        progressFill.frame = CGRect(x: 0, y: 0, width: 0, height: 1.5)
        progressFill.cornerRadius = 0.75
        progressFill.startPoint = CGPoint(x: 0, y: 0.5)
        progressFill.endPoint = CGPoint(x: 1, y: 0.5)
        progressHolder.addSublayer(progressFill)
        card.addSublayer(progressHolder)
    }

    private func configureText(_ l: CATextLayer, frame: CGRect, font: NSFont, size: CGFloat, alpha: CGFloat) {
        l.frame = frame
        l.font = font
        l.fontSize = size
        l.foregroundColor = NSColor(white: 1, alpha: alpha).cgColor
        l.truncationMode = .end
        l.isWrapped = false
        l.alignmentMode = .left
        l.contentsScale = scale
        l.string = ""
    }

    private func blurFilters() -> [Any] {
        guard let f = CIFilter(name: "CIGaussianBlur") else { return [] }
        f.name = "blur"
        f.setValue(0, forKey: kCIInputRadiusKey)
        return [f]
    }

    private func symbolName(for control: String, playing: Bool) -> String {
        switch control {
        case "playpause": return playing ? "pause.fill" : "play.fill"
        case "next track": return "forward.fill"
        default: return "backward.fill"
        }
    }

    private func setSymbol(_ l: CALayer, name: String, fade: Double) {
        let pt: CGFloat = (name == "play.fill" || name == "pause.fill") ? 13 : 10.5
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pt, weight: .regular))
        else { return }
        let img = NSImage(size: base.size, flipped: false) { r in
            base.draw(in: r)
            NSColor.white.set()
            r.fill(using: .sourceAtop)
            return true
        }
        if fade > 0 { crossfade(l, fade) }
        l.bounds = CGRect(origin: .zero, size: img.size)
        l.contents = img
    }

    // MARK: Transitions

    private func crossfade(_ l: CALayer, _ duration: Double) {
        let t = CATransition()
        t.type = .fade
        t.duration = duration
        t.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        l.add(t, forKey: "crossfade")
    }

    private func applyPalette(_ p: [NSColor], duration: Double) {
        let c0 = p.first ?? defaultPalette[0]
        let c1 = p.count > 1 ? p[1] : c0
        let soft0 = c0.blended(withFraction: 0.3, of: .white) ?? c0
        let soft1 = c1.blended(withFraction: 0.3, of: .white) ?? c1

        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        if duration == 0 { CATransaction.setDisableActions(true) }
        blobA.colors = [c0.withAlphaComponent(0.42).cgColor, c0.withAlphaComponent(0.14).cgColor, c0.withAlphaComponent(0).cgColor]
        blobB.colors = [c1.withAlphaComponent(0.34).cgColor, c1.withAlphaComponent(0.11).cgColor, c1.withAlphaComponent(0).cgColor]
        waveA.strokeColor = soft0.withAlphaComponent(0.75).cgColor
        waveB.strokeColor = soft1.withAlphaComponent(0.35).cgColor
        progressFill.colors = [soft0.withAlphaComponent(0.85).cgColor, soft1.withAlphaComponent(0.85).cgColor]
        CATransaction.commit()
    }

    private func blurred(_ img: NSImage) -> CGImage? {
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let ci = CIImage(cgImage: cg)
        let s = 96 / max(ci.extent.width, 1)
        let small = ci.transformed(by: CGAffineTransform(scaleX: s, y: s))
        let soft = small.clampedToExtent()
            .applyingGaussianBlur(sigma: 14)
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.35])
            .cropped(to: small.extent)
        return IslandController.ciContext.createCGImage(soft, from: small.extent)
    }

    /// Called when artwork for a song has loaded
    func setArt(_ img: NSImage, palette: [NSColor], key: String) {
        readyKey = key
        readyArt = img
        readyPalette = palette
    }

    private func applyArt() {
        guard let art = readyArt else { return }
        appliedArtKey = readyKey
        crossfade(artLayer, 2.0)
        artLayer.contents = art
        crossfade(tint, 2.4)
        tint.contents = blurred(art)
        applyPalette(readyPalette, duration: 2.2)
    }

    // MARK: Placement

    func refreshVisibility() {
        if enabled {
            place()
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }

    func place() {
        let screen = NSScreen.screens.first(where: { $0.visibleFrame.minY - $0.frame.minY > 20 })
            ?? NSScreen.main ?? NSScreen.screens[0]
        let inset = DockEdge.current() == .bottom
            ? max(0, screen.visibleFrame.minY - screen.frame.minY) : 0
        let cardBottom = IslandController.cardCenter.y - IslandController.cardSize.height / 2
        panel.setFrameOrigin(NSPoint(x: screen.frame.midX - IslandController.panelSize.width / 2,
                                     y: screen.frame.minY + inset + 16 - cardBottom))
    }

    // MARK: Hit testing (panel coordinates -> card coordinates)

    private var currentScale: CGFloat { 0.985 + 0.015 * vis + 0.012 * hover }

    private func local(_ p: NSPoint) -> CGPoint {
        let c = IslandController.cardCenter
        let s = currentScale
        let cs = IslandController.cardSize
        return CGPoint(x: (p.x - c.x) / s + cs.width / 2, y: (p.y - c.y) / s + cs.height / 2)
    }

    private func control(at p: NSPoint) -> String? {
        guard hover > 0.5 else { return nil }
        let l = local(p)
        for (name, c) in IslandController.controlCenters where hypot(l.x - c.x, l.y - c.y) < 13 {
            return name
        }
        return nil
    }

    // MARK: Frame loop

    private func setVisibleLayers(_ o: Float) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        card.opacity = o
        shadowLayer.opacity = o
        glowRoot.opacity = o
        CATransaction.commit()
        effect.alphaValue = CGFloat(o)
    }

    func tick(_ rawDt: CGFloat) {
        guard enabled else { return }
        let dt = min(rawDt, 1.0 / 30.0)
        let now = ProcessInfo.processInfo.systemUptime
        clock += dt
        let playing = track?.playing == true

        // Song changes: wait briefly for the new artwork so everything turns over together
        if let t = track, t.key != shownKey {
            if changeStarted == nil { changeStarted = now }
            if readyKey == t.key || now - (changeStarted ?? now) > 1.8 {
                shownKey = t.key
                changeStarted = nil
                crossfade(titleLayer, 1.4)
                titleLayer.string = t.title
                crossfade(artistLayer, 1.7)
                artistLayer.string = t.artist
            }
        }
        if !shownKey.isEmpty && readyKey == shownKey && appliedArtKey != shownKey {
            applyArt()
        }
        if shownPlaying != playing, let l = controlLayers["playpause"] {
            setSymbol(l, name: symbolName(for: "playpause", playing: playing), fade: shownPlaying == nil ? 0 : 0.35)
            shownPlaying = playing
        }

        if playing {
            pausedSince = nil
        } else if pausedSince == nil {
            pausedSince = Date()
        }
        let pausedFor = pausedSince.map { Date().timeIntervalSince($0) } ?? 0

        // Hover: only take the mouse while it is over the card
        let mouse = NSEvent.mouseLocation
        let mouseInPanel = NSPoint(x: mouse.x - panel.frame.minX, y: mouse.y - panel.frame.minY)
        let m = local(mouseInPanel)
        let cs = IslandController.cardSize
        let over = vis > 0.3 && m.x > -6 && m.y > -6 && m.x < cs.width + 6 && m.y < cs.height + 6
        if panel.ignoresMouseEvents == over { panel.ignoresMouseEvents = !over }

        let present = track != nil && !shownKey.isEmpty && (playing || pausedFor < 45 || over)
        approach(&vis, present ? 1 : 0, rate: 2.2, dt: dt)
        approach(&hover, over ? 1 : 0, rate: 4.5, dt: dt)
        approach(&dim, playing ? 1 : 0.6, rate: 1.5, dt: dt)

        if !present && vis < 0.005 {
            if !asleep { setVisibleLayers(0); asleep = true }
            return
        }
        asleep = false

        // Music level, smoothed so motion stays slow
        var target: CGFloat = 0
        var low: CGFloat = 0
        if playing {
            if audioLive, let l = levels {
                let raw = [l.rms, l.low, l.high]
                var n = [CGFloat](repeating: 0, count: 3)
                let decay = Float(pow(0.5, Double(dt) / 3.0))
                for i in 0..<3 {
                    peaks[i] = max(raw[i], max(0.01, peaks[i] * decay))
                    n[i] = CGFloat(min(1, raw[i] / peaks[i]))
                }
                target = 0.3 + 0.7 * n[0]
                low = n[1]
            } else {
                target = 0.55 + 0.12 * sin(clock * 0.8)
                low = 0.5
            }
        }
        approach(&level, target, rate: 2.5, dt: dt)
        approach(&beat, low, rate: 6, dt: dt)
        phaseA += dt * (0.9 + level * 0.6)
        phaseB -= dt * (0.6 + level * 0.4)

        // Parallax towards the cursor, very small
        let px = over ? (m.x / cs.width - 0.5) * 3 : 0
        let py = over ? (m.y / cs.height - 0.5) * 2 : 0
        approach(&parallax.x, px, rate: 4, dt: dt)
        approach(&parallax.y, py, rate: 4, dt: dt)

        for (name, c) in IslandController.controlCenters {
            let near = over && hypot(m.x - c.x, m.y - c.y) < 13
            var v = controlHover[name] ?? 0
            approach(&v, near ? 1 : 0, rate: 8, dt: dt)
            controlHover[name] = v
        }

        let s = currentScale
        let lift = (1 - vis) * 6
        let center = CGPoint(x: IslandController.cardCenter.x, y: IslandController.cardCenter.y - lift)
        let alpha = vis * (0.8 + 0.2 * hover)
        let transform = CATransform3DMakeScale(s, s, 1)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        card.position = center
        card.transform = transform
        card.opacity = Float(alpha)
        shadowLayer.position = center
        shadowLayer.transform = transform
        shadowLayer.opacity = Float(vis * 0.9)
        glowRoot.opacity = Float(vis * dim * (0.85 + 0.15 * beat))
        glowRoot.position = CGPoint(x: glowRoot.bounds.midX - parallax.x * 2, y: glowRoot.bounds.midY - parallax.y * 2)

        artHolder.position = CGPoint(x: 36 + parallax.x, y: 36 + parallax.y)
        artLayer.opacity = Float(0.72 + 0.28 * dim)

        waveHolder.opacity = Float((1 - hover) * (0.45 + 0.55 * dim))
        waveHolder.setValue((hover) * 4, forKeyPath: "filters.blur.inputRadius")
        waveA.path = wavePath(amp: level, phase: phaseA, freq: 1.5)
        waveB.path = wavePath(amp: level * 0.7, phase: phaseB, freq: 2.2)

        controlsHolder.opacity = Float(hover)
        controlsHolder.setValue((1 - hover) * 4, forKeyPath: "filters.blur.inputRadius")
        for (name, l) in controlLayers {
            l.opacity = Float(0.6 + 0.4 * (controlHover[name] ?? 0))
        }

        progressHolder.opacity = Float(hover * 0.9)
        let d = track?.duration ?? 0
        let prog = d > 0 ? CGFloat(min(1, max(0, position / d))) : 0
        progressFill.frame = CGRect(x: 0, y: 0, width: progressHolder.bounds.width * prog, height: 1.5)
        CATransaction.commit()

        // Glass follows the card's scale and fade
        let ef = NSRect(x: center.x - cs.width * s / 2, y: center.y - cs.height * s / 2,
                        width: cs.width * s, height: cs.height * s)
        if abs(ef.minX - lastEffectFrame.minX) > 0.05 || abs(ef.minY - lastEffectFrame.minY) > 0.05
            || abs(ef.width - lastEffectFrame.width) > 0.05 {
            effect.frame = ef
            lastEffectFrame = ef
        }
        effect.alphaValue = alpha
    }

    private func wavePath(amp: CGFloat, phase: CGFloat, freq: CGFloat) -> CGPath {
        let w = waveHolder.bounds.width, h = waveHolder.bounds.height
        let n = 48
        let path = CGMutablePath()
        for i in 0...n {
            let t = CGFloat(i) / CGFloat(n)
            let envelope = pow(sin(.pi * t), 1.5)
            let y = h / 2 + amp * h * 0.42 * envelope * sin(t * freq * 2 * .pi + phase)
            let pt = CGPoint(x: t * w, y: y)
            if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
        }
        return path
    }
}
