import Foundation

final class NamingAndSettingsTests: RegressionCase {
    func testEndpointAppendsPathBeforeQueryAndPreservesEncodedValues() {
        checkEqual(LLMNamer.endpoint(from: "https://example.com/v1/?api-version=2026-01#docs")?.absoluteString,
                       "https://example.com/v1/chat/completions?api-version=2026-01")
        checkEqual(LLMNamer.endpoint(from: "http://127.0.0.1:11434")?.path, "/v1/chat/completions")
        checkEqual(LLMNamer.endpoint(from: "https://example.com/v1/chat/completions?q=a%2Fb")?.query, "q=a%2Fb")
        checkEqual(LLMNamer.endpoint(from: "https://example.com/v1/chat/completions?q=1")?.path, "/v1/chat/completions")
        checkNil(LLMNamer.endpoint(from: "file:///tmp/model"))
        checkNil(LLMNamer.endpoint(from: "https://user:secret@example.com"))
    }

    func testCorruptPreferencesCannotOverflowOrRequestUnboundedResources() throws {
        let suite = "JustRecorderTests.\(UUID().uuidString)"
        let defaults = try unwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Int.max, forKey: "autoStopMinutes")
        defaults.set(Int.max, forKey: "preRollSeconds")
        defaults.set(-1, forKey: "hotKeyCode")
        defaults.set(-1, forKey: "hotKeyModifiers")
        defaults.set(0, forKey: "sampleRate")
        defaults.set(-10, forKey: "maxTitleLength")
        defaults.set(-8.0, forKey: "aiTimeoutSeconds")
        defaults.set(Int.max, forKey: "aacBitrateKbps")
        let settings = Settings(defaults: defaults)
        checkEqual(settings.autoStopMinutes, 10)
        checkEqual(settings.preRollSeconds, 15)
        checkEqual(settings.sampleRate, 48_000)
        checkEqual(settings.maxTitleLength, 70)
        checkEqual(settings.aiTimeout, 8)
        checkEqual(settings.aacBitrateKbps, 256)
        checkEqual(settings.hotKeyDisplayString, "⌥⌘R")
    }

    func testNamingHandlesOptionalArtistAndLongUnicodeWithoutHiddenFiles() {
        checkEqual(NameTemplate.render("[{artist} - ]{title} {duration}",
            context: NameContext(title: "Song", duration: "1m3s")), "Song 1m3s")
        let name = NameTemplate.render("{title}", context: NameContext(title: String(repeating: "\u{754C}🎶", count: 100)))
        checkLessThanOrEqual(name.utf8.count, 200)
        checkFalse(FilenameSanitizer.sanitize("...song").hasPrefix("."))
        checkEqual(FilenameSanitizer.sanitize("song", maxLength: -1), "")
    }
    func testMenuStatusPreservesFullMessageWithoutClassifyingTrackWords() {
        let title = "Error — Permission Denied " + String(repeating: "\u{754C}", count: 60) + ".m4a"
        let saved = RecordingStatus(message: title, needsAttention: false)
        checkFalse(saved.needsAttention)
        checkEqual(saved.message, title)
        checkLessThanOrEqual(saved.menuCaption.count, 72)
        checkTrue(saved.menuCaption.hasSuffix(".m4a"))
        let failed = RecordingStatus(message: "The disk is full.\nChoose another folder.", needsAttention: true)
        checkTrue(failed.needsAttention)
        checkFalse(failed.menuCaption.contains("\n"))
    }

}
