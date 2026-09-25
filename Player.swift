import Cocoa

struct Track {
    var app: String            // "Spotify" or "Music"
    var title: String
    var artist: String
    var playing: Bool
    var position: Double       // seconds
    var duration: Double       // seconds
    var artworkURL: String?
    var key: String { "\(app)|\(title)|\(artist)" }
}

enum Player {
    static let apps: [(name: String, bundle: String)] = [
        ("Spotify", "com.spotify.client"),
        ("Music", "com.apple.Music")
    ]

    static func bundle(for app: String) -> String? {
        apps.first(where: { $0.name == app })?.bundle
    }

    static func isRunning(_ bundle: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty
    }

    @discardableResult
    static func run(_ source: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error == nil ? result : nil
    }

    static func query(_ app: String) -> Track? {
        let art = app == "Spotify" ? "(artwork url of t)" : "\"\""
        let dur = app == "Spotify" ? "((duration of t) / 1000)" : "(duration of t)"
        let src = """
        tell application "\(app)"
            if player state is stopped then return ""
            set t to current track
            set s to character id 31
            return (player state as string) & s & (name of t) & s & (artist of t) & s & (player position as string) & s & (\(dur) as string) & s & \(art)
        end tell
        """
        guard let str = run(src)?.stringValue, !str.isEmpty else { return nil }
        let p = str.components(separatedBy: "\u{1F}")
        guard p.count >= 6 else { return nil }
        func num(_ s: String) -> Double { Double(s.replacingOccurrences(of: ",", with: ".")) ?? 0 }
        return Track(app: app, title: p[1], artist: p[2], playing: p[0] == "playing",
                     position: num(p[3]), duration: num(p[4]),
                     artworkURL: p[5].isEmpty ? nil : p[5])
    }

    static func musicArtwork() -> NSImage? {
        for field in ["raw data", "data"] {
            if let d = run("tell application \"Music\" to get \(field) of artwork 1 of current track")?.data,
               let img = NSImage(data: d) {
                return img
            }
        }
        return nil
    }

    static func send(_ command: String, to app: String) {
        run("tell application \"\(app)\" to \(command)")
    }
}
