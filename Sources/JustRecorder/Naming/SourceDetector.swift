import Foundation
import AppKit
import CoreGraphics

/// Everything JustRecorder knows about what was playing when a capture started.
struct SourceInfo {
    var appName: String = ""
    var rawWindowTitle: String = ""
    var track: String?
    var artist: String?
    var cleanedTitle: String = ""
    /// How the title was obtained — surfaced in Settings so the heuristic is debuggable.
    var method: String = "none"

    static let unknown = SourceInfo(appName: "", cleanedTitle: "", method: "none")

    /// Best human title available, never empty.
    func bestTitle(fallback: String = "Snippet") -> String {
        if let track, !track.isEmpty { return track }
        if !cleanedTitle.isEmpty { return cleanedTitle }
        if !appName.isEmpty { return appName }
        return fallback
    }
}

/// Figures out *what* was playing: which app, and what its window / track title says.
enum SourceDetector {

    // Priority buckets. Music apps beat video players, which beat browsers.
    private static let musicApps: Set<String> = [
        "com.apple.Music", "com.apple.iTunes", "com.spotify.client",
        "com.netease.163music", "com.tencent.QQMusicMac", "com.kugou.mac",
        "com.apple.podcasts", "com.tidal.desktop", "com.deezer.deezer-desktop",
        "com.doppler.mac", "org.swinsian.Swinsian", "com.apple.GarageBand10",
        "com.apple.logic10", "com.ableton.live", "com.native-instruments.Traktor"
    ]

    private static let videoApps: Set<String> = [
        "com.apple.QuickTimePlayerX", "org.videolan.vlc", "com.colliderli.iina",
        "com.plexapp.plex", "tv.plex.desktop", "com.apple.TV", "com.netflix.Netflix",
        "com.bilibili.player.mac", "com.tencent.tenvideo", "com.iqiyi.player"
    ]

    private static let browsers: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.google.Chrome",
        "com.google.Chrome.canary", "org.chromium.Chromium", "com.microsoft.edgemac",
        "com.brave.Browser", "org.mozilla.firefox", "company.thebrowser.Browser",
        "company.thebrowser.dia", "com.operasoftware.Opera", "com.vivaldi.Vivaldi",
        "app.zen-browser.zen", "com.kagi.kagimacOS"
    ]

    private static let chatAndOther: Set<String> = [
        "com.tencent.xinWeChat", "com.tencent.WeWorkMac", "ru.keepcoder.Telegram",
        "com.hnc.Discord", "us.zoom.xos", "com.microsoft.teams2", "com.ss.mac.bytedance.lark",
        "com.electron.lark", "com.bytedance.macos.douyin", "com.smartisan.Bytedance-\u{98DE}\u{4E66}"
    ]

    /// Thread-safe handoff for `detectWithTimeout`: the background work may still be
    /// running (and writing) after the caller has given up on it.
    private final class DetectionBox {
        private let lock = NSLock()
        private var value: SourceInfo?
        private var abandoned = false

        func store(_ info: SourceInfo) {
            lock.lock()
            defer { lock.unlock() }
            guard !abandoned else { return }
            value = info
        }

        func read() -> SourceInfo? {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        /// After this, a late `store` is ignored, so it cannot overwrite what the
        /// caller already returned.
        func abandon() {
            lock.lock()
            abandoned = true
            lock.unlock()
        }
    }

    /// Serial queue that owns the blocking part of detection.
    ///
    /// `detectWithTimeout` blocks its caller by design, so it must never run on a Swift
    /// concurrency cooperative-pool thread (see `detectAsync`).
    private static let detectionQueue = DispatchQueue(
        label: "com.riffapp.Riff.detection",
        qos: .userInitiated
    )

    /// `async` entry point for callers inside a `Task`.
    static func detectAsync(useAppleScript: Bool, timeout: TimeInterval = 2.0) async -> SourceInfo {
        await withCheckedContinuation { (continuation: CheckedContinuation<SourceInfo, Never>) in
            detectionQueue.async {
                continuation.resume(
                    returning: detectWithTimeout(useAppleScript: useAppleScript, timeout: timeout)
                )
            }
        }
    }

    /// Runs detection on a background queue with a hard timeout, because AppleScript
    /// round-trips to a busy player can take a moment.
    static func detectWithTimeout(useAppleScript: Bool, timeout: TimeInterval = 2.0) -> SourceInfo {
        let box = DetectionBox()
        let semaphore = DispatchSemaphore(value: 0)

        DispatchQueue.global(qos: .userInitiated).async {
            box.store(detect(useAppleScript: useAppleScript))
            semaphore.signal()
        }

        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            box.abandon()
            Log.warn("Source detection timed out; falling back to the frontmost app.")
            return frontmostFallback()
        }
        return box.read() ?? SourceInfo.unknown
    }

    static func detect(useAppleScript: Bool) -> SourceInfo {
        let playingPIDs = AudioProcessProbe.pidsCurrentlyPlayingAudio()
        let candidates = rankedCandidates(playingPIDs: playingPIDs)
        // Fetch window titles once, only if player metadata is unavailable.
        var titleSnapshot: [pid_t: String]?
        func windowTitles() -> [pid_t: String] {
            if let titleSnapshot { return titleSnapshot }
            let fresh = frontmostWindowTitles()
            titleSnapshot = fresh
            return fresh
        }

        var audioActiveFallback: SourceInfo?

        for app in candidates {
            if let audioActiveFallback, !playingPIDs.contains(app.processIdentifier) {
                return audioActiveFallback
            }
            // Never the literal string "Unknown": it would end up in `{app}` and, via
            // `bestTitle()`, in the file name itself. An empty name falls through to
            // "Snippet", which at least does not pretend to be information.
            let appName = app.localizedName ?? app.bundleIdentifier ?? ""
            let bundleID = app.bundleIdentifier

            // 1. Ask Music / Spotify directly — by far the most accurate metadata.
            if useAppleScript, let bundleID {
                switch MediaScript.status(bundleID: bundleID) {
                case .playing(let metadata):
                    var info = SourceInfo()
                    info.appName = appName
                    // Track names arrive decorated often enough ("🎵 Song",
                    // "Now Playing: Song") that the cleaner is worth running here too —
                    // and `bestTitle()` returns `track`, so cleaning only `cleanedTitle`
                    // would have had no effect at all.
                    let cleaned = TitleCleaner.clean(metadata.track, appName: appName)
                    let track = cleaned.isEmpty ? metadata.track : cleaned
                    info.track = track
                    info.artist = metadata.artist
                    info.rawWindowTitle = metadata.track
                    info.cleanedTitle = track
                    info.method = "AppleScript (\(appName))"
                    return info

                case .idle:
                    // The player answered "nothing is playing". Its window title is just
                    // "Spotify" / "Music", which must not beat the app that really is
                    // playing — especially before macOS 14.4, where there is no Core
                    // Audio probe to rank candidates by.
                    continue

                case .unavailable:
                    break // not scriptable, no Automation permission, or it timed out
                }
            }

            // 2. Otherwise read the app's frontmost window title.
            let windowTitleText = windowTitles()[app.processIdentifier]
            if let windowTitleText, !windowTitleText.isEmpty {
                let cleaned = TitleCleaner.clean(windowTitleText, appName: appName)
                if !cleaned.isEmpty {
                    var info = SourceInfo()
                    info.appName = appName
                    info.rawWindowTitle = windowTitleText
                    info.cleanedTitle = cleaned
                    let (artist, track) = splitArtistAndTrack(cleaned)
                    info.artist = artist
                    info.track = track
                    info.method = playingPIDs.contains(app.processIdentifier)
                        ? "Window title (audio active: \(appName))"
                        : "Window title (\(appName))"
                    return info
                }
            }

            // Nothing usable from this app. Keep its name if it is the one Core Audio
            // says is playing, and carry on down the list.
            if audioActiveFallback == nil,
               !appName.isEmpty,
               playingPIDs.contains(app.processIdentifier) {
                var info = SourceInfo()
                info.appName = appName
                info.rawWindowTitle = windowTitleText ?? ""
                info.method = "App name (audio active: \(appName))"
                audioActiveFallback = info
            }
        }

        return audioActiveFallback ?? frontmostFallback(windowTitles: titleSnapshot)
    }

    // MARK: - Candidate ranking

    private static func rankedCandidates(playingPIDs: Set<pid_t>) -> [NSRunningApplication] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier

        func score(_ app: NSRunningApplication) -> Int {
            var value = 0
            if playingPIDs.contains(app.processIdentifier) { value += 1000 }
            if let bundleID = app.bundleIdentifier {
                if musicApps.contains(bundleID) { value += 120 }
                else if videoApps.contains(bundleID) { value += 90 }
                else if browsers.contains(bundleID) { value += 60 }
                else if chatAndOther.contains(bundleID) { value += 20 }
            }
            if app.processIdentifier == frontmostPID { value += 40 }
            if app.isHidden { value -= 15 }
            return value
        }

        var scored: [(app: NSRunningApplication, score: Int)] = []
        scored.reserveCapacity(8)
        for app in NSWorkspace.shared.runningApplications {
            guard app.processIdentifier != ownPID,
                  !app.isTerminated,
                  app.activationPolicy == .regular || playingPIDs.contains(app.processIdentifier)
            else { continue }
            let value = score(app)
            if value > 0 { scored.append((app: app, score: value)) }
        }

        return scored
            .sorted { $0.score > $1.score }
            .prefix(6)
            .map(\.app)
    }

    private static func frontmostFallback(windowTitles: [pid_t: String]? = nil) -> SourceInfo {
        var info = SourceInfo()
        // JustRecorder itself must never be the answer: starting a capture from the status menu
        // makes this accessory app the frontmost one, which named clips "JustRecorder 5s.m4a".
        // With no app name, `bestTitle()` falls through to "Snippet".
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else {
            info.method = "none"
            return info
        }
        let appName = app.localizedName ?? app.bundleIdentifier ?? ""
        info.appName = appName
        // Reuses the caller's snapshot when there is one; the detection-timeout path has
        // none, and only then is a window list fetched here.
        if let title = (windowTitles ?? frontmostWindowTitles())[app.processIdentifier] {
            info.rawWindowTitle = title
            info.cleanedTitle = TitleCleaner.clean(title, appName: appName)
        }
        info.method = "Frontmost app (\(appName.isEmpty ? "unnamed" : appName))"
        return info
    }

    // MARK: - Window titles

    static func frontmostWindowTitles() -> [pid_t: String] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return [:]
        }

        var titles: [pid_t: String] = [:]
        titles.reserveCapacity(16)
        for window in windows {
            guard let ownerPID = window[kCGWindowOwnerPID as String] as? pid_t,
                  titles[ownerPID] == nil,
                  let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
                  let name = window[kCGWindowName as String] as? String
            else { continue }

            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { titles[ownerPID] = trimmed }
        }
        return titles
    }

    /// Splits `Artist - Song` into its parts when the shape is unambiguous.
    private static func splitArtistAndTrack(_ title: String) -> (artist: String?, track: String?) {
        for separator in [" - ", " – ", " — "] {
            let parts = title.components(separatedBy: separator)
            if parts.count == 2 {
                let left = parts[0].trimmingCharacters(in: .whitespaces)
                let right = parts[1].trimmingCharacters(in: .whitespaces)
                if !left.isEmpty, !right.isEmpty, left.count <= 40 {
                    return (left, right)
                }
            }
        }
        return (nil, nil)
    }
}

/// Reads "now playing" metadata straight from Music / Spotify.
enum MediaScript {

    struct Metadata {
        let track: String
        let artist: String?
    }

    /// Why the three outcomes matter: "the player answered, and it is idle" has to be
    /// distinguishable from "the player could not be asked". In the first case the app
    /// must be skipped (its window title is just "Spotify"); in the second it still
    /// deserves the window-title fallback.
    enum Outcome {
        case playing(Metadata)
        case idle
        case unavailable
    }

    /// Budget for one player round-trip. Deliberately short: `detect` may ask two
    /// players (Music and Spotify), and both round-trips together must still fit inside
    /// `SourceDetector.detectWithTimeout`'s 2 s budget.
    private static let scriptTimeout: TimeInterval = 0.8

    static func status(bundleID: String) -> Outcome {
        let appName: String
        switch bundleID {
        case "com.spotify.client": appName = "Spotify"
        case "com.apple.Music", "com.apple.iTunes": appName = "Music"
        default: return .unavailable
        }
        guard !Thread.isMainThread else { return .unavailable }
        let source = """
        if application "\(appName)" is running then
            tell application "\(appName)"
                if player state is playing then
                    set trackName to ""
                    set artistName to ""
                    try
                        set trackName to name of current track
                    end try
                    try
                        set artistName to artist of current track
                    end try
                    return trackName & "\t" & artistName
                end if
            end tell
        end if
        return ""
        """

        guard let result = MetadataProcess.run(executable: "/usr/bin/osascript", arguments: ["-e", source], timeout: scriptTimeout) else {
            return .unavailable
        }
        let raw = result.trimmingCharacters(in: .newlines)
        guard !raw.isEmpty else { return .idle }

        let parts = raw.components(separatedBy: "\t")
        let track = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Playing, but the player would not name the track: let the window title try.
        guard !track.isEmpty else { return .unavailable }

        let artist = parts.count > 1
            ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        return .playing(Metadata(track: track, artist: artist.isEmpty ? nil : artist))
    }
}
