import Cocoa

// Afterglow: ambient light for your Mac that follows what Spotify or Apple Music is playing.

final class AppDelegate: NSObject, NSApplicationDelegate {
    let tile = TileView(frame: NSRect(x: 0, y: 0, width: 128, height: 128))
    let overlay = Overlay()
    let island = IslandController()
    var audioTap: AnyObject?

    var track: Track?
    var polledAt = Date()
    var artKey = ""
    var artRetries = 0
    var targetAccent = defaultPalette[0]
    var speed: CGFloat = 0
    var lastFrame = ProcessInfo.processInfo.systemUptime
    var lastIslandFrame = ProcessInfo.processInfo.systemUptime
    var idleFrames = 0
    var timers: [Timer] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        tile.frame = NSRect(origin: .zero, size: NSApp.dockTile.size)
        NSApp.dockTile.contentView = tile
        NSApp.dockTile.display()

        overlay.rebuild()
        island.view.onControl = { [weak self] cmd in self?.control(cmd) }
        island.view.onOpen = { [weak self] in self?.openPlayer() }
        island.refreshVisibility()

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.overlay.rebuild()
            self?.island.place()
        }

        startAudio()
        poll()

        let pollTimer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.poll() }
        let frameTimer = Timer(timeInterval: 1.0 / 24.0, repeats: true) { [weak self] _ in self?.frame() }
        let islandTimer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.islandFrame() }
        let flowTimer = Timer(timeInterval: 7.0, repeats: true) { [weak self] _ in self?.overlay.flow() }
        for t in [pollTimer, frameTimer, islandTimer, flowTimer] { RunLoop.main.add(t, forMode: .common) }
        timers = [pollTimer, frameTimer, islandTimer, flowTimer]
    }

    func startAudio() {
        if #available(macOS 13.0, *) {
            let tap = AudioTap()
            tap.onLevels = { [weak self] l in
                self?.island.levels = l
                self?.island.audioLive = true
            }
            tap.onFailure = { [weak self] in self?.island.audioLive = false }
            tap.start()
            audioTap = tap
        }
    }

    func poll() {
        var found: [Track] = []
        for app in Player.apps where Player.isRunning(app.bundle) {
            if let t = Player.query(app.name) { found.append(t) }
        }
        track = found.first(where: { $0.playing }) ?? found.first
        polledAt = Date()
        overlay.setPlaying(track?.playing == true)
        island.track = track

        guard let t = track else {
            artKey = ""
            tile.artwork = nil
            return
        }
        if t.key != artKey {
            artKey = t.key
            artRetries = 0
            loadArtwork(for: t)
        } else if tile.artwork == nil && artRetries < 5 {
            artRetries += 1
            loadArtwork(for: t)
        }
    }

    func loadArtwork(for t: Track) {
        let key = t.key
        if t.app == "Music" {
            apply(Player.musicArtwork(), key: key)
        } else if let s = t.artworkURL, let url = URL(string: s) {
            URLSession.shared.dataTask(with: url) { data, _, _ in
                let img = data.flatMap { NSImage(data: $0) }
                DispatchQueue.main.async { self.apply(img, key: key) }
            }.resume()
        }
    }

    func apply(_ img: NSImage?, key: String) {
        guard key == artKey, let img = img else { return }
        tile.artwork = img
        let pal = img.palette()
        targetAccent = pal[0]
        overlay.setPalette(pal)
        island.setArt(img, palette: pal, key: key)
        idleFrames = 0
        tile.needsDisplay = true
        NSApp.dockTile.display()
    }

    func currentPosition() -> Double {
        guard let t = track else { return 0 }
        var p = t.position
        if t.playing { p += Date().timeIntervalSince(polledAt) }
        return t.duration > 0 ? min(p, t.duration) : p
    }

    func islandFrame() {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = CGFloat(now - lastIslandFrame)
        lastIslandFrame = now
        island.position = currentPosition()
        island.tick(dt)
    }

    func frame() {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = CGFloat(min(0.1, now - lastFrame))
        lastFrame = now

        let playing = track?.playing == true
        overlay.setBeat(island.audioLive ? island.beat : 1)

        let targetSpeed: CGFloat = playing ? .pi * 0.5 : 0
        speed += (targetSpeed - speed) * min(1, dt * 1.5)
        tile.angle = (tile.angle + speed * dt).truncatingRemainder(dividingBy: .pi * 2)
        tile.glow += ((playing ? 1 : 0) - tile.glow) * min(1, dt * 1.2)
        tile.pulse += dt * 1.3
        tile.accent = tile.accent.blended(withFraction: min(1, dt * 2), of: targetAccent) ?? targetAccent
        if let t = track, t.duration > 0 {
            tile.progress = CGFloat(currentPosition() / t.duration)
        } else {
            tile.progress = 0
        }

        let settled = !playing && speed < 0.01 && tile.glow < 0.02
        if settled {
            idleFrames += 1
            if idleFrames % 24 != 0 { return }
        } else {
            idleFrames = 0
        }
        tile.needsDisplay = true
        NSApp.dockTile.display()
    }

    // Right-click menu on the dock icon
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        if let t = track {
            menu.addItem(NSMenuItem(title: t.title, action: nil, keyEquivalent: ""))
            menu.addItem(NSMenuItem(title: "\(t.artist)  ·  \(t.app)", action: nil, keyEquivalent: ""))
            menu.addItem(.separator())
            menu.addItem(item(t.playing ? "Pause" : "Play", #selector(playPause)))
            menu.addItem(item("Next", #selector(nextTrack)))
            menu.addItem(item("Previous", #selector(previousTrack)))
        } else {
            menu.addItem(NSMenuItem(title: "Nothing playing", action: nil, keyEquivalent: ""))
        }

        menu.addItem(.separator())
        let islandItem = item("Now playing card", #selector(toggleIsland))
        islandItem.state = island.enabled ? .on : .off
        menu.addItem(islandItem)

        let glowItem = NSMenuItem(title: "Ambient glow", action: nil, keyEquivalent: "")
        let glowMenu = NSMenu()
        for m in GlowMode.allCases {
            let i = item(m.title, #selector(setMode(_:)))
            i.tag = m.rawValue
            i.state = overlay.mode == m ? .on : .off
            glowMenu.addItem(i)
        }
        glowMenu.addItem(.separator())
        for x in GlowIntensity.allCases {
            let i = item(x.title, #selector(setIntensity(_:)))
            i.tag = x.rawValue
            i.state = overlay.intensity == x ? .on : .off
            glowMenu.addItem(i)
        }
        glowItem.submenu = glowMenu
        menu.addItem(glowItem)
        return menu
    }

    func item(_ title: String, _ sel: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        i.target = self
        return i
    }

    @objc func toggleIsland() { island.enabled.toggle() }
    @objc func setMode(_ sender: NSMenuItem) { overlay.mode = GlowMode(rawValue: sender.tag) ?? .edges }
    @objc func setIntensity(_ sender: NSMenuItem) { overlay.intensity = GlowIntensity(rawValue: sender.tag) ?? .subtle }
    @objc func playPause() { control("playpause") }
    @objc func nextTrack() { control("next track") }
    @objc func previousTrack() { control("previous track") }

    func control(_ command: String) {
        guard let t = track else { return }
        Player.send(command, to: t.app)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.poll() }
    }

    func openPlayer() {
        guard let t = track, let bundle = Player.bundle(for: t.app),
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        playPause()
        NSApp.hide(nil)
        return false
    }

    func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Afterglow",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        NSApp.mainMenu = main
    }
}

// MARK: - Entry point

let app = NSApplication.shared

// Used by build.sh to render the static app icon
if let i = CommandLine.arguments.firstIndex(of: "--render-icon"), i + 1 < CommandLine.arguments.count {
    let v = TileView(frame: NSRect(x: 0, y: 0, width: 1024, height: 1024))
    v.glow = 0.8; v.progress = 0.35; v.angle = 0.6; v.pulse = .pi / 2
    if let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
    }
    exit(0)
}

let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
