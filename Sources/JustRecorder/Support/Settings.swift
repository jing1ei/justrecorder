import Foundation
import AppKit

/// All user preferences, persisted in `UserDefaults` (the API key lives in the Keychain).
final class Settings {

    /// Posted (main thread, synchronously) after any stored preference is written.
    static let didChange = Notification.Name("com.riffapp.Riff.settingsDidChange")

    static let shared = Settings()

    private let d: UserDefaults

    private func notifyChange() {
        NotificationCenter.default.post(name: Settings.didChange, object: self)
    }

    private enum K {
        static let saveFolder = "saveFolderPath"
        static let format = "audioFormat"
        static let aacBitrate = "aacBitrateKbps"
        static let mp3Bitrate = "mp3BitrateKbps"
        static let sampleRate = "sampleRate"
        static let hotKeyCode = "hotKeyCode"
        static let hotKeyModifiers = "hotKeyModifiers"
        static let playSounds = "playSounds"
        static let showTimer = "showTimerInMenuBar"
        static let revealAfterSave = "revealAfterSave"
        static let autoStopMinutes = "autoStopMinutes"
        static let preRollEnabled = "preRollEnabled"
        static let preRollSeconds = "preRollSeconds"
        static let nameTemplate = "nameTemplate"
        static let maxTitleLength = "maxTitleLength"
        static let useAppleScriptMetadata = "useAppleScriptMetadata"
        static let aiEnabled = "aiNamingEnabled"
        static let aiBaseURL = "aiBaseURL"
        static let aiModel = "aiModel"
        static let aiPrompt = "aiSystemPrompt"
        static let aiTimeout = "aiTimeoutSeconds"
    }

    // MARK: - Defaults

    static let defaultNameTemplate = "[{artist} - ]{title} {duration}"

    static let defaultMaxTitleLength = 70

    static let defaultAIPrompt = """
    You clean up raw macOS window titles into short, human-friendly file names for saved music snippets.

    Rules:
    - Reply with the file name text ONLY: no extension, no quotes, no explanation, no trailing period.
    - Keep the song and/or artist name when present. Format as "Artist - Song" when both are clear.
    - Remove player/app/site noise: browser names, "YouTube", "bilibili", view counts, unread badges like "(3)", \
    "Now Playing", episode chrome, marketing words, emoji.
    - Keep the original language of the source title. Never translate.
    - Never include the clip length or a duration in the name — JustRecorder appends that itself.
    - Never invent details that are not in the input. If nothing meaningful is there, reply exactly: Unknown Snippet
    - Max 60 characters. No slashes, colons or line breaks.
    """

    static var defaultSaveFolder: String {
        let music = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Music")
        return music.appendingPathComponent("JustRecorder Captures").path
    }

    // MARK: - Stored properties
    //
    // Every one of these persists in its own `didSet` and then posts `didChange`. The
    // property names, types and defaults are exactly what `Recording/` and `Naming/` read.

    var saveFolder: String { didSet { d.set(saveFolder, forKey: K.saveFolder); notifyChange() } }
    var format: AudioFormatKind { didSet { d.set(format.rawValue, forKey: K.format); notifyChange() } }
    var aacBitrateKbps: Int { didSet { d.set(aacBitrateKbps, forKey: K.aacBitrate); notifyChange() } }

    var hotKeyCode: Int { didSet { d.set(hotKeyCode, forKey: K.hotKeyCode); notifyChange() } }
    var hotKeyModifiers: Int { didSet { d.set(hotKeyModifiers, forKey: K.hotKeyModifiers); notifyChange() } }

    var playSounds: Bool { didSet { d.set(playSounds, forKey: K.playSounds); notifyChange() } }
    var autoStopMinutes: Int { didSet { d.set(autoStopMinutes, forKey: K.autoStopMinutes); notifyChange() } }

    var preRollEnabled: Bool { didSet { d.set(preRollEnabled, forKey: K.preRollEnabled); notifyChange() } }
    var preRollSeconds: Int { didSet { d.set(preRollSeconds, forKey: K.preRollSeconds); notifyChange() } }

    var nameTemplate: String { didSet { d.set(nameTemplate, forKey: K.nameTemplate); notifyChange() } }
    var useAppleScriptMetadata: Bool { didSet { d.set(useAppleScriptMetadata, forKey: K.useAppleScriptMetadata); notifyChange() } }

    var aiEnabled: Bool { didSet { d.set(aiEnabled, forKey: K.aiEnabled); notifyChange() } }
    var aiBaseURL: String { didSet { d.set(aiBaseURL, forKey: K.aiBaseURL); notifyChange() } }
    var aiModel: String { didSet { d.set(aiModel, forKey: K.aiModel); notifyChange() } }
    var aiSystemPrompt: String { didSet { d.set(aiSystemPrompt, forKey: K.aiPrompt); notifyChange() } }

    // MARK: - Hidden defaults
    let sampleRate: Int
    let mp3BitrateKbps: Int
    let maxTitleLength: Int
    let revealAfterSave: Bool
    let showTimerInMenuBar: Bool
    let aiTimeout: Double

    /// Not persisted in UserDefaults — proxied to the Keychain.
    var aiAPIKey: String {
        get {
            (Keychain.readWithFallback() ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    @discardableResult
    func saveAPIKey(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let saved = trimmed.isEmpty ? Keychain.delete() : Keychain.write(trimmed)
        if saved { notifyChange() }
        return saved
    }

    // MARK: - Init

    init(defaults: UserDefaults = .standard) {
        d = defaults
        saveFolder = d.string(forKey: K.saveFolder) ?? Settings.defaultSaveFolder
        format = AudioFormatKind(rawValue: d.string(forKey: K.format) ?? "") ?? .aac
        aacBitrateKbps = Self.choice(d.integer(forKey: K.aacBitrate), in: AudioFormatKind.aacBitrateChoices, fallback: 256)
        mp3BitrateKbps = Self.choice(d.integer(forKey: K.mp3Bitrate), in: [32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320], fallback: 320)
        sampleRate = Self.choice(d.integer(forKey: K.sampleRate), in: [44_100, 48_000], fallback: 48_000)

        // Default hotkey: ⌥⌘R
        hotKeyCode = Self.bounded(d.object(forKey: K.hotKeyCode) as? Int, to: 0...127, fallback: Int(KeyCodes.r))
        let supportedModifiers = Int(NSEvent.ModifierFlags([.command, .option, .control, .shift]).rawValue)
        let storedModifiers = d.object(forKey: K.hotKeyModifiers) as? Int ?? 0
        let modifiers = storedModifiers >= 0 ? storedModifiers & supportedModifiers : 0
        hotKeyModifiers = modifiers != 0 ? modifiers : Int(NSEvent.ModifierFlags([.command, .option]).rawValue)

        playSounds = d.object(forKey: K.playSounds) as? Bool ?? true
        showTimerInMenuBar = d.object(forKey: K.showTimer) as? Bool ?? true
        revealAfterSave = d.object(forKey: K.revealAfterSave) as? Bool ?? false
        autoStopMinutes = Self.bounded(d.object(forKey: K.autoStopMinutes) as? Int, to: 0...30, fallback: 10)

        preRollEnabled = d.object(forKey: K.preRollEnabled) as? Bool ?? false
        preRollSeconds = Self.bounded(d.object(forKey: K.preRollSeconds) as? Int, to: 5...30, fallback: 15)

        nameTemplate = d.string(forKey: K.nameTemplate) ?? Settings.defaultNameTemplate
        maxTitleLength = Self.bounded(d.object(forKey: K.maxTitleLength) as? Int, to: 1...150, fallback: Self.defaultMaxTitleLength)
        useAppleScriptMetadata = d.object(forKey: K.useAppleScriptMetadata) as? Bool ?? true

        aiEnabled = d.object(forKey: K.aiEnabled) as? Bool ?? false
        aiBaseURL = d.string(forKey: K.aiBaseURL) ?? "https://api.openai.com/v1"
        aiModel = d.string(forKey: K.aiModel) ?? "gpt-4o-mini"
        aiSystemPrompt = d.string(forKey: K.aiPrompt) ?? Settings.defaultAIPrompt
        let timeout = d.object(forKey: K.aiTimeout) as? Double ?? 8.0
        aiTimeout = timeout.isFinite && (2...120).contains(timeout) ? timeout : 8.0
    }

    private static func choice(_ value: Int, in choices: [Int], fallback: Int) -> Int {
        choices.contains(value) ? value : fallback
    }

    private static func bounded(_ value: Int?, to range: ClosedRange<Int>, fallback: Int) -> Int {
        guard let value, range.contains(value) else { return fallback }
        return value
    }

    // MARK: - Derived

    var saveFolderURL: URL { URL(fileURLWithPath: saveFolder, isDirectory: true) }

    var modifierFlags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: UInt(hotKeyModifiers)) }

    var hotKeyDisplayString: String {
        KeyCodes.displayString(keyCode: UInt16(hotKeyCode), modifiers: modifierFlags)
    }

    /// Effective format: MP3 silently degrades to AAC when no encoder is installed.
    var effectiveFormat: AudioFormatKind {
        if format == .mp3 && MP3Transcoder.locateEncoder() == nil { return .aac }
        return format
    }

    func ensureSaveFolderExists() {
        try? FileManager.default.createDirectory(at: saveFolderURL, withIntermediateDirectories: true)
    }
}
