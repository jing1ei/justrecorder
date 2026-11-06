import AppKit

// MARK: - Visual language

/// Dynamic light/dark colors shared by settings and the menu-bar indicator.
enum JustRecorderPalette {

    static var accentNSColor: NSColor { .controlAccentColor }

    /// The faintest possible fill, for a block of returned text or an editor.
    static let washNSColor = NSColor(name: "justRecorderWash") { appearance in
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return dark ? NSColor(white: 1, alpha: 0.06) : NSColor(white: 0, alpha: 0.045)
    }
}

extension AudioFormatKind {
    /// Short, quiet label for a pop-up row: "AAC · .m4a".
    ///
    /// `displayName` carries advice ("— recommended", "— needs lame/ffmpeg") that belongs
    /// in one caption, not in every row of every list.
    var formatLabel: String { "\(shortName) · .\(fileExtension)" }
}

// MARK: - Window

/// Builds the settings window on first open and **throws it away when it closes**.
final class SettingsWindowController: NSObject, NSWindowDelegate {

    static let shared = SettingsWindowController()

    private var window: NSWindow?

    /// The live panel. Held so the close path can talk to it directly (commit the API key,
    /// tear the hotkey monitor down) instead of hoping `deinit` runs at the right moment.
    private var panel: SettingsPanelController?

    /// The window on its way out, kept alive for exactly one turn of the run loop after
    /// `windowWillClose`.
    private var retiredWindow: NSWindow?

    /// The one entry point; `MenuBarController` and `AppDelegate` both call this.
    func show() {
        let target: NSWindow
        // `window` is already nil the moment a close begins, so a rapid reopen builds a
        // fresh window rather than ordering a dying one back on screen — and never two.
        if let existing = window {
            target = existing
        } else {
            let newPanel = SettingsPanelController(settings: .shared)
            let newWindow = NSWindow(contentViewController: newPanel)
            newWindow.title = "JustRecorder Settings"
            // No minimise button: an accessory app has no Dock tile to restore a
            // miniaturised window from, so it could only ever be lost. Not resizable
            // either — the column has one width, and every section scrolls.
            newWindow.styleMask = [.titled, .closable]
            newWindow.setContentSize(SettingsPanelController.windowSize)
            // AppKit must not free the window itself on close: it is released here, one
            // run-loop turn after `windowWillClose` has returned.
            newWindow.isReleasedWhenClosed = false
            newWindow.delegate = self
            newWindow.center()
            window = newWindow
            panel = newPanel
            target = newWindow
        }
        NSApp.activate(ignoringOtherApps: true)
        target.makeKeyAndOrderFront(nil)
        // Reopening an already-visible panel preserves the user's place.
    }

    func commitPendingEdits() {
        guard let window else { return }
        window.makeFirstResponder(nil)
        panel?.commitPendingEdits()
    }

    func canTerminate() -> Bool {
        guard let window else { return true }
        return windowShouldClose(window)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.makeFirstResponder(nil)
        guard panel?.hasUnsavedAPIKey == true else { return true }
        let alert = NSAlert()
        alert.messageText = "The API key could not be saved"
        alert.informativeText = "Keep Settings open to retry, or discard the unsaved key. Other settings have been saved."
        alert.addButton(withTitle: "Keep Editing")
        alert.addButton(withTitle: "Discard Key")
        guard alert.runModal() == .alertSecondButtonReturn else { return false }
        panel?.discardUnsavedAPIKey()
        return true
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else { return }

        // Commit whatever is being typed. A field that still owns the field editor has not
        // ended editing yet, and the view tree is about to go away; resigning first
        // responder forces `controlTextDidEndEditing` / `textDidEndEditing` while there is
        // still something to commit into.
        closing.makeFirstResponder(nil)

        // Belt and braces after that: every editor is re-read and written if it differs,
        // the hotkey monitor is removed and the notification observers go.
        panel?.prepareToClose()

        closing.delegate = nil
        window = nil
        panel = nil
        retiredWindow = closing
        DispatchQueue.main.async { [weak self, closing] in
            if self?.retiredWindow === closing { self?.retiredWindow = nil }
        }
    }
}

// MARK: - Layout metrics

private enum Metrics {
    /// The window is not resizable, so the column has exactly one width and every
    /// full-width element can be pinned to it with a plain constant. No frame maths, no
    /// ambiguity, and wrapping labels get an honest `preferredMaxLayoutWidth`.
    static let columnWidth: CGFloat = 404
    static let pageInset: CGFloat = 28
    static let sectionGap: CGFloat = 24
    static let rowPadding: CGFloat = 9
    static let fieldWidth: CGFloat = 208
    static let valueWidth: CGFloat = 224
    static let tokenColumn: CGFloat = 86
    static let promptHeight: CGFloat = 116
}

// MARK: - Panel

/// One calm panel: a single scrolling column of quiet section labels, hairline
/// separators, and values flush right so they all line up.
final class SettingsPanelController: NSViewController, NSTextFieldDelegate, NSTextViewDelegate {

    static let windowSize = NSSize(width: 460, height: 640)

    private let settings: Settings

    // MARK: Container

    private let scrollView = NSScrollView()
    private let column = TopDownStackView()
    private let navigation = NSSegmentedControl(labels: ["Capture", "Naming", "AI naming", "General"],
        trackingMode: .selectOne, target: nil, action: nil)
    private var pages: [NSStackView] = []
    private var activeColumn: NSStackView?
    private var aiTestTask: Task<Void, Never>?
    private var isClosed = false
    private let behaviorResultLabel = NSTextField(labelWithString: "")
    private var behaviorResultBlock: NSView?

    // MARK: Controls kept for read-back or restyling

    private let hotKeyButton = NSButton(title: "", target: nil, action: nil)
    private let hotKeyWarning = NSImageView()
    private let savePathLabel = NSTextField(labelWithString: "")
    private let autoStopPopUp = NSPopUpButton(frame: .zero, pullsDown: false)

    private let formatPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let bitratePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let sizeLabel = NSTextField(labelWithString: "")
    private let mp3Warning = NSImageView()
    private let mp3NoteLabel = NSTextField(labelWithString: "")
    private var bitrateRow: NSView?
    private var bitrateCaption: NSView?
    private var mp3NoteRow: NSView?
    private var formatExtraHairline: NSView?

    private let preRollSwitch = NSSwitch()
    private let preRollPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let preRollCaption = NSTextField(labelWithString: "")
    private var preRollHairline: NSView?
    private var preRollRow: NSView?
    private var preRollCaptionRow: NSView?

    private let templateField = NSTextField(string: "")
    private let previewLabel = NSTextField(labelWithString: "")

    private let appleScriptSwitch = NSSwitch()
    private let detectButton = NSButton(title: "", target: nil, action: nil)
    private let detectionLabel = NSTextField(labelWithString: "")
    private var detectionBlock: NSView?

    private let aiSwitch = NSSwitch()
    private let baseURLField = NSTextField(string: "")
    private let modelField = NSTextField(string: "")
    private let apiKeyField = NSSecureTextField()
    private let promptTextView = NSTextView()
    private let aiTestButton = NSButton(title: "", target: nil, action: nil)
    private let aiResultLabel = NSTextField(labelWithString: "")
    private var aiResultBlock: NSView?

    private let launchSwitch = NSSwitch()
    private let soundsSwitch = NSSwitch()

    private let permissionIcon = NSImageView()
    private let permissionLabel = NSTextField(labelWithString: "")
    private let permissionCaption = NSTextField(labelWithString: "")
    private var permissionCaptionRow: NSView?

    // MARK: Transient state

    /// The hotkey capture monitor, when the field is listening. Removed on every teardown
    /// path — a monitor left armed keeps swallowing this app's key events, including the
    /// ones meant for the API-key field further down the column.
    private var hotKeyMonitor: Any?
    private var isListeningForHotKey = false

    /// Which MP3 encoder is installed, resolved when the panel opens and again whenever
    /// the format changes or the window comes back to the front. `nil` means "looked, and
    /// there is none". Never resolved from a layout or a draw: the lookup stats up to
    /// seven paths on disk.
    private var mp3EncoderName: String?

    /// What is already in the Keychain, so a keystroke never has to read it back and a
    /// commit can tell whether there is anything to write.
    private var savedAPIKey = ""

    private var isDetecting = false
    private var isTesting = false

    // MARK: - Life cycle

    init(settings: Settings) {
        self.settings = settings
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SettingsPanelController is created in code only.")
    }

    deinit {
        // Last resort only; `prepareToClose` has normally done both already.
        if let hotKeyMonitor { NSEvent.removeMonitor(hotKeyMonitor) }
        NotificationCenter.default.removeObserver(self)
    }

    override func loadView() {
        let root = NSView(frame: NSRect(origin: .zero, size: SettingsPanelController.windowSize))

        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 0
        column.edgeInsets = NSEdgeInsets(
            top: 20,
            left: Metrics.pageInset,
            bottom: 26,
            right: Metrics.pageInset
        )
        column.translatesAutoresizingMaskIntoConstraints = false

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        // Overlay scrollers keep the clip view exactly as wide as the window, so the
        // column's two margins stay equal.
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = column

        navigation.translatesAutoresizingMaskIntoConstraints = false
        navigation.selectedSegment = 0
        navigation.target = self
        navigation.action = #selector(selectPage(_:))
        navigation.setAccessibilityLabel("Settings category")
        root.addSubview(navigation)
        root.addSubview(scrollView)

        let width = scrollView.widthAnchor.constraint(
            equalToConstant: SettingsPanelController.windowSize.width
        )
        let height = scrollView.heightAnchor.constraint(
            equalToConstant: SettingsPanelController.windowSize.height - 52
        )
        // These two only have to size the window on first open; if macOS ever hands the
        // window a smaller frame (a very short screen), they yield instead of fighting it.
        width.priority = .defaultHigh
        height.priority = .defaultHigh

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            navigation.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            navigation.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Metrics.pageInset),
            navigation.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Metrics.pageInset),
            scrollView.topAnchor.constraint(equalTo: navigation.bottomAnchor, constant: 12),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            width,
            height,
            // Vertical scrolling only: the column is as wide as the clip view and as tall
            // as its content. No bottom pin — that is what lets it grow.
            column.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            column.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor)
        ])

        view = root
        buildColumn()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // Everything expensive happens once, here — never from a layout pass or a draw.
        // `SMAppService.status` is an XPC round-trip, `CGPreflightScreenCaptureAccess` a
        // TCC lookup, the encoder search a walk over seven paths, and the API key a
        // Keychain round-trip.
        launchSwitch.state = LaunchAtLogin.isEnabled ? .on : .off
        applyPermissionState(ScreenRecordingPermission.isGranted)

        // The user may have installed lame/ffmpeg since the last look.
        MP3Transcoder.invalidateEncoderCache()
        mp3EncoderName = MP3Transcoder.locateEncoder()?.displayName

        savedAPIKey = settings.aiAPIKey
        apiKeyField.stringValue = savedAPIKey

        refreshFormatSection()
        refreshPreRollSection()
        refreshPreview()
        refreshHotKeyField()

        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(hotKeyRegistrationChanged),
            name: HotKeyManager.registrationDidChange,
            object: nil
        )
        // Filtered to this window inside the handlers, so an open panel, an alert or the
        // menu bar cannot trigger any of this.
        center.addObserver(
            self,
            selector: #selector(windowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(windowDidResignKey(_:)),
            name: NSWindow.didResignKeyNotification,
            object: nil
        )
    }

    var hasUnsavedAPIKey: Bool {
        apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) != savedAPIKey
    }

    func discardUnsavedAPIKey() {
        apiKeyField.stringValue = savedAPIKey
    }

    func commitPendingEdits() { commitAllEdits() }

    /// Called from `SettingsWindowController.windowWillClose`, before the window is let go.
    func prepareToClose() {
        isClosed = true
        aiTestTask?.cancel()
        aiTestTask = nil
        stopListeningForHotKey()
        commitAllEdits()
        NotificationCenter.default.removeObserver(self)
    }

    @objc func selectPage(_ sender: NSSegmentedControl) {
        guard pages.indices.contains(sender.selectedSegment) else { return }
        view.window?.makeFirstResponder(sender)
        stopListeningForHotKey()
        commitAllEdits()
        for (index, page) in pages.enumerated() { page.isHidden = index != sender.selectedSegment }
        view.layoutSubtreeIfNeeded()
        scrollToTop()
        view.window?.recalculateKeyViewLoop()
    }

    func scrollToTop() {
        // The column is flipped, so (0, 0) is its top. Done explicitly rather than trusted
        // so a reopened window never appears mid-column.
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}

/// A stack view that lays out from the top down, so the scroll view opens at the top of
/// the column instead of at the bottom of it.
private final class TopDownStackView: NSStackView {
    override var isFlipped: Bool { true }
}

// MARK: - Building the column

private extension SettingsPanelController {

    func buildColumn() {
        for index in 0..<4 {
            let page = NSStackView()
            page.orientation = .vertical
            page.alignment = .leading
            page.spacing = 0
            page.translatesAutoresizingMaskIntoConstraints = false
            page.widthAnchor.constraint(equalToConstant: Metrics.columnWidth).isActive = true
            column.addArrangedSubview(page)
            pages.append(page)
            activeColumn = page
            switch index {
            case 0:
                buildCaptureSection()
                buildFormatSection()
                buildPreRollSection()
            case 1:
                buildNamingSection()
                buildDetectionSection()
                buildTokenSection()
            case 2:
                buildAISection()
            default:
                buildPermissionSection()
                buildBehaviourSection()
            }
            page.isHidden = index != 0
        }
        activeColumn = nil
    }

    // MARK: Capture

    func buildCaptureSection() {
        appendSection("Capture", first: true)

        hotKeyButton.target = self
        hotKeyButton.action = #selector(hotKeyButtonPressed)
        hotKeyButton.bezelStyle = .rounded
        hotKeyButton.font = NSFont.systemFont(ofSize: 12)
        hotKeyButton.translatesAutoresizingMaskIntoConstraints = false
        hotKeyButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 148).isActive = true

        configureWarningIcon(
            hotKeyWarning,
            tooltip: "Another app already owns this shortcut, so JustRecorder never receives it. Pick a different one."
        )

        let hotKeyValue = makeValueStack([hotKeyWarning, hotKeyButton], spacing: 8)
        hotKeyButton.setAccessibilityLabel("Recording shortcut")
        hotKeyButton.toolTip = "Click, then press a key with Command, Option, Control or Shift. Escape cancels."
        appendRow("Shortcut", value: hotKeyValue)
        appendHairline()

        configureValueLabel(savePathLabel, mono: false, truncation: .byTruncatingHead, maxWidth: 174)
        savePathLabel.stringValue = shortPath(settings.saveFolder)
        savePathLabel.toolTip = settings.saveFolder
        let changeButton = makeQuietButton("Change…", action: #selector(chooseFolder))
        appendRow("Save to", value: makeValueStack([savePathLabel, changeButton], spacing: 12))
        appendHairline()

        configurePopUp(
            autoStopPopUp,
            choices: [
                ("2 minutes", 2), ("5 minutes", 5), ("10 minutes", 10),
                ("30 minutes", 30), ("Never", 0)
            ],
            selected: settings.autoStopMinutes,
            fallbackTitle: "\(settings.autoStopMinutes) minutes",
            action: #selector(autoStopChanged(_:))
        )
        appendRow("Auto-stop after", value: autoStopPopUp)
    }

    // MARK: Format

    func buildFormatSection() {
        appendSection("Format")

        formatPopUp.removeAllItems()
        for format in AudioFormatKind.allCases {
            formatPopUp.addItem(withTitle: format.formatLabel)
            // The row stays short; the advice ("— recommended", "— needs lame/ffmpeg")
            // lives in the tooltip and in the caption below instead of shouting from
            // every line. Pure string switch, no filesystem.
            formatPopUp.lastItem?.toolTip = format.displayName
        }
        formatPopUp.selectItem(at: AudioFormatKind.allCases.firstIndex(of: settings.format) ?? 0)
        formatPopUp.target = self
        formatPopUp.action = #selector(formatChanged(_:))
        formatPopUp.font = NSFont.systemFont(ofSize: 13)
        formatPopUp.translatesAutoresizingMaskIntoConstraints = false
        appendRow("Recording format", value: formatPopUp)
        appendHairline()

        configurePopUp(
            bitratePopUp,
            choices: AudioFormatKind.aacBitrateChoices.map { ("\($0) kbps", $0) },
            selected: settings.aacBitrateKbps,
            fallbackTitle: "\(settings.aacBitrateKbps) kbps",
            action: #selector(bitrateChanged(_:))
        )
        bitrateRow = appendRow("Bitrate", value: bitratePopUp)
        bitrateCaption = appendCaption("macOS encodes AAC natively. The default is 256 kbps.")

        configureWarningIcon(mp3Warning, tooltip: nil)
        configureCaption(mp3NoteLabel, text: "", width: Metrics.columnWidth - 24)
        let noteStack = NSStackView(views: [mp3Warning, mp3NoteLabel])
        noteStack.orientation = .horizontal
        // Top, not first-baseline: an image view has no baseline of its own, so AppKit
        // would align its top edge with the caption's first baseline and drop it half a
        // line too low.
        noteStack.alignment = .top
        noteStack.spacing = 7
        noteStack.distribution = .fill
        noteStack.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 10, right: 0)
        mp3NoteLabel.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        mp3NoteRow = append(noteStack)

        formatExtraHairline = appendHairline()

        configureValueLabel(sizeLabel, mono: false, truncation: .byTruncatingTail, maxWidth: nil)
        appendRow("Roughly", value: sizeLabel)
    }

    // MARK: Pre-roll

    func buildPreRollSection() {
        appendSection("Pre-roll")

        configureSwitch(preRollSwitch, on: settings.preRollEnabled, action: #selector(preRollToggled(_:)))
        appendRow("Include recent audio", value: preRollSwitch)
        appendCaption("Keep audio from before you press the recording shortcut.")

        preRollHairline = appendHairline()

        configurePopUp(
            preRollPopUp,
            choices: [("5 seconds", 5), ("10 seconds", 10), ("15 seconds", 15), ("30 seconds", 30)],
            selected: settings.preRollSeconds,
            fallbackTitle: "\(settings.preRollSeconds) seconds",
            action: #selector(preRollSecondsChanged(_:))
        )
        preRollRow = appendRow("Keep", value: preRollPopUp)

        configureCaption(preRollCaption, text: "", width: Metrics.columnWidth)
        preRollCaption.widthAnchor.constraint(equalToConstant: Metrics.columnWidth).isActive = true
        preRollCaptionRow = append(wrap(preRollCaption, top: 2, bottom: 10))
    }

    // MARK: File name

    func buildNamingSection() {
        appendSection("File name")

        configureTextField(templateField, mono: true, text: settings.nameTemplate)
        templateField.setAccessibilityLabel("File name template")
        templateField.constraints.first(where: { $0.firstAttribute == .width })?.constant = Metrics.columnWidth
        append(wrap(templateField, top: 4, bottom: 8))
        appendHairline()

        appendCaption("Preview", top: 8, bottom: 4)
        configureResultLabel(previewLabel)
        previewLabel.setAccessibilityLabel("File name preview")
        previewLabel.preferredMaxLayoutWidth = Metrics.columnWidth
        previewLabel.widthAnchor.constraint(equalToConstant: Metrics.columnWidth).isActive = true
        append(wrap(previewLabel, top: 0, bottom: 8))

        appendTrailingButton(makeQuietButton("Restore the default template", action: #selector(restoreTemplate)))
    }

    // MARK: Tokens

    func buildTokenSection() {
        appendSection("Tokens")

        for entry in NameTemplate.tokenHelp {
            let token = NSTextField(labelWithString: entry.token)
            token.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            token.textColor = .labelColor
            token.lineBreakMode = .byTruncatingTail
            token.maximumNumberOfLines = 1
            token.translatesAutoresizingMaskIntoConstraints = false
            token.widthAnchor.constraint(equalToConstant: Metrics.tokenColumn).isActive = true

            let detail = makeCaption(entry.detail, width: Metrics.columnWidth - Metrics.tokenColumn - 14)
            detail.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)

            let row = NSStackView(views: [token, detail])
            row.orientation = .horizontal
            row.alignment = .firstBaseline
            row.spacing = 14
            row.distribution = .fill
            row.edgeInsets = NSEdgeInsets(top: 3, left: 0, bottom: 3, right: 0)
            append(row)
        }

        appendCaption("""
        Anything in square brackets disappears when a token inside it is empty, so \
        [{artist} - ]{title} {duration} becomes “Song 1m3s” when no artist is known.
        """, top: 8)
    }

    // MARK: Source detection

    func buildDetectionSection() {
        appendSection("Source detection")

        configureSwitch(
            appleScriptSwitch,
            on: settings.useAppleScriptMetadata,
            action: #selector(appleScriptToggled(_:))
        )
        appendRow("Ask players for the exact track", value: appleScriptSwitch)
        appendCaption("""
        JustRecorder picks the app that is really playing, then uses its track metadata or its \
        window title. macOS asks once before JustRecorder may talk to Music or Spotify.
        """)

        setQuietTitle(detectButton, "Test detection now", enabled: true)
        detectButton.target = self
        detectButton.action = #selector(runDetection)
        appendRow(
            leading: makeCaption("Check the current source.", width: 190),
            trailing: detectButton,
            padding: 4
        )

        configureResultLabel(detectionLabel)
        detectionBlock = append(makeWashBlock(around: detectionLabel))
    }

    // MARK: AI naming

    func buildAISection() {
        appendSection("AI naming")

        configureSwitch(aiSwitch, on: settings.aiEnabled, action: #selector(aiToggled(_:)))
        appendRow("Let a model tidy up the name", value: aiSwitch)
        appendCaption("""
        JustRecorder sends only the window or track title, the artist when a player exposes one, \
        the app name and the clip length. Audio is never uploaded. If the call fails, the \
        locally cleaned title is used — a recording is never lost to a naming error.
        """)
        appendHairline()

        configureTextField(baseURLField, mono: true, text: settings.aiBaseURL)
        appendRow("Base URL", value: baseURLField)
        appendHairline()

        configureTextField(modelField, mono: true, text: settings.aiModel)
        appendRow("Model", value: modelField)
        appendHairline()

        configureTextField(apiKeyField, mono: true, text: "")
        appendRow("API key", value: apiKeyField)
        appendCaption("""
        Any OpenAI-compatible /chat/completions endpoint works — a hosted one, or a local \
        model at http://127.0.0.1:11434/v1 (Ollama) or http://127.0.0.1:1234/v1 \
        (LM Studio). The key is kept in your login Keychain, and a local model needs none.
        """)

        append(makePromptEditor())
        appendTrailingButton(makeQuietButton("Restore the default prompt", action: #selector(restorePrompt)))

        setQuietTitle(aiTestButton, "Send a sample title", enabled: true)
        aiTestButton.target = self
        aiTestButton.action = #selector(runAITest)
        appendRow(
            leading: makeCaption("Test with a sample title.", width: 190),
            trailing: aiTestButton,
            padding: 4
        )

        configureResultLabel(aiResultLabel)
        aiResultBlock = append(makeWashBlock(around: aiResultLabel))
    }

    // MARK: Behaviour

    func buildBehaviourSection() {
        appendSection("Behaviour")

        // The state is filled in from `SMAppService` in `viewDidLoad`, never here.
        configureSwitch(launchSwitch, on: false, action: #selector(launchAtLoginToggled(_:)))
        appendRow("Launch at login", value: launchSwitch)
        appendHairline()

        configureSwitch(soundsSwitch, on: settings.playSounds, action: #selector(soundsToggled(_:)))
        appendRow("Start and stop sounds", value: soundsSwitch)
        configureResultLabel(behaviorResultLabel)
        behaviorResultBlock = append(makeWashBlock(around: behaviorResultLabel))
    }

    // MARK: Permission

    func buildPermissionSection() {
        appendSection("Permission")

        permissionIcon.imageScaling = .scaleNone
        permissionIcon.translatesAutoresizingMaskIntoConstraints = false

        permissionLabel.font = NSFont.systemFont(ofSize: 13)
        permissionLabel.textColor = .labelColor
        permissionLabel.lineBreakMode = .byWordWrapping
        permissionLabel.maximumNumberOfLines = 0
        permissionLabel.preferredMaxLayoutWidth = Metrics.columnWidth - 24
        permissionLabel.stringValue = "Checking…"

        let statusStack = NSStackView(views: [permissionIcon, permissionLabel])
        statusStack.orientation = .horizontal
        // Centred for the same reason as the MP3 note: the glyph has no baseline.
        statusStack.alignment = .centerY
        statusStack.spacing = 7
        statusStack.distribution = .fill
        statusStack.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 4, right: 0)
        permissionLabel.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        append(statusStack)

        appendTrailingButton(
            makeQuietButton("Open System Settings", action: #selector(openSystemSettings))
        )

        configureCaption(permissionCaption, text: """
        If access is already enabled, quit all copies and reopen the installed app. \
        Start a recording to verify access. A rebuilt app may need its permission entry refreshed.
        """, width: Metrics.columnWidth)
        permissionCaption.widthAnchor.constraint(equalToConstant: Metrics.columnWidth).isActive = true
        permissionCaptionRow = append(wrap(permissionCaption, top: 2, bottom: 0))
    }
}

// MARK: - View factory

private extension SettingsPanelController {

    /// Adds one full-width element to the column.
    @discardableResult
    func append(_ subview: NSView) -> NSView {
        subview.translatesAutoresizingMaskIntoConstraints = false
        (activeColumn ?? column).addArrangedSubview(subview)
        subview.widthAnchor.constraint(equalToConstant: Metrics.columnWidth).isActive = true
        return subview
    }

    /// A section: a small, letter-spaced label and the rows under it. Sections are told
    /// apart by whitespace and hairlines — there are no boxes anywhere in this window.
    func appendSection(_ title: String, first: Bool = false) {
        if !(activeColumn?.arrangedSubviews.isEmpty ?? first) { append(makeSpacer(Metrics.sectionGap)) }
        let label = NSTextField(labelWithAttributedString: NSAttributedString(
            string: title.uppercased(),
            attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                .kern: 1.3,
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        ))
        append(wrap(label, top: 0, bottom: 5))
    }

    @discardableResult
    func appendHairline() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        line.alphaValue = 0.6
        let height = line.heightAnchor.constraint(equalToConstant: 1)
        // 999, not required: if a future AppKit gives a separator box an intrinsic height
        // of its own, this yields quietly instead of logging a broken constraint.
        height.priority = NSLayoutConstraint.Priority(999)
        height.isActive = true
        return append(line)
    }

    /// One line of the page: label on the left, the value flush right so every value in
    /// the window lines up in a single column.
    @discardableResult
    func appendRow(_ text: String, value: NSView) -> NSView {
        value.setAccessibilityLabel(text)
        return appendRow(leading: makeRowLabel(text), trailing: value, padding: Metrics.rowPadding)
    }

    @discardableResult
    func appendRow(leading: NSView, trailing: NSView, padding: CGFloat) -> NSView {
        leading.translatesAutoresizingMaskIntoConstraints = false
        trailing.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [leading, trailing])
        row.orientation = .horizontal
        // Centred rather than baseline-aligned: the value column mixes text, switches and
        // pop-up menus, and a switch has no baseline to align a label to.
        row.alignment = .centerY
        row.spacing = 16
        row.distribution = .fill
        row.edgeInsets = NSEdgeInsets(top: padding, left: 0, bottom: padding, right: 0)

        // The label absorbs all the slack, so the value ends flush with the right margin
        // whatever kind of control it is.
        leading.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        trailing.setContentHuggingPriority(.required, for: .horizontal)
        return append(row)
    }

    /// A row that is nothing but one text action, set against the right margin.
    func appendTrailingButton(_ button: NSButton) {
        appendRow(leading: makeSpacer(1), trailing: button, padding: 4)
    }

    @discardableResult
    func appendCaption(_ text: String, top: CGFloat = 2, bottom: CGFloat = 10) -> NSView {
        let caption = makeCaption(text, width: Metrics.columnWidth)
        caption.widthAnchor.constraint(equalToConstant: Metrics.columnWidth).isActive = true
        // The *wrapper* is returned, not the label: a caption that can be hidden has to
        // take its own padding with it, or it leaves a gap behind.
        return append(wrap(caption, top: top, bottom: bottom))
    }

    /// Vertical padding around one element, expressed as a stack's edge insets rather than
    /// as spacer views.
    func wrap(_ subview: NSView, top: CGFloat, bottom: CGFloat) -> NSStackView {
        subview.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView(views: [subview])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: top, left: 0, bottom: bottom, right: 0)
        return stack
    }

    func makeSpacer(_ height: CGFloat) -> NSView {
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.heightAnchor.constraint(equalToConstant: height).isActive = true
        return spacer
    }

    func makeRowLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 13)
        label.textColor = .labelColor
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.preferredMaxLayoutWidth = Metrics.columnWidth - Metrics.valueWidth - 16
        return label
    }

    /// Secondary copy: short, human, and always in the lighter tone. Wraps, so it needs an
    /// honest `preferredMaxLayoutWidth` to report the right height.
    func makeCaption(_ text: String, width: CGFloat) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        configureCaption(label, text: text, width: width)
        return label
    }

    func configureCaption(_ label: NSTextField, text: String, width: CGFloat) {
        label.stringValue = text
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.preferredMaxLayoutWidth = width
        label.translatesAutoresizingMaskIntoConstraints = false
    }

    /// A value in the right-hand column: quiet, monospaced digits, and never wide enough
    /// to push the row's label off the left margin.
    func configureValueLabel(
        _ label: NSTextField,
        mono: Bool,
        truncation: NSLineBreakMode,
        maxWidth: CGFloat?
    ) {
        label.font = mono
            ? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            : NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        label.lineBreakMode = truncation
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        if let maxWidth {
            label.widthAnchor.constraint(lessThanOrEqualToConstant: maxWidth).isActive = true
        }
    }

    /// Text that came back from somewhere — a detection probe, a model — as a block of
    /// monospaced type on the faintest of washes.
    func configureResultLabel(_ label: NSTextField) {
        label.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.isSelectable = true
        label.preferredMaxLayoutWidth = Metrics.columnWidth - 20
        label.translatesAutoresizingMaskIntoConstraints = false
    }

    /// The wash behind a result block is a sibling pinned to all four edges, so the block's
    /// height comes from the label alone and nothing has to be measured by hand.
    func makeWashBlock(around label: NSTextField) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.widthAnchor.constraint(equalToConstant: Metrics.columnWidth).isActive = true

        let background = NSBox()
        background.boxType = .custom
        background.borderWidth = 0
        background.cornerRadius = 6
        background.fillColor = JustRecorderPalette.washNSColor
        background.titlePosition = .noTitle
        background.contentViewMargins = .zero
        background.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(background)
        container.addSubview(label)

        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            background.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            background.topAnchor.constraint(equalTo: container.topAnchor),
            background.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8)
        ])

        let wrapper = wrap(container, top: 6, bottom: 2)
        wrapper.isHidden = true // nothing to show until something comes back
        return wrapper
    }

    func makeValueStack(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        for subview in views { subview.translatesAutoresizingMaskIntoConstraints = false }
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = spacing
        stack.distribution = .fill
        return stack
    }

    /// A text-only action, set the way a printed page sets a footnote link: no bezel, the
    /// one accent colour, never more than one to a row.
    func makeQuietButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        setQuietTitle(button, title, enabled: true)
        return button
    }

    func setQuietTitle(_ button: NSButton, _ title: String, enabled: Bool) {
        button.title = title
        button.setAccessibilityLabel(title)
        button.isBordered = false
        button.setButtonType(.momentaryChange)
        // An attributed title, not `contentTintColor`: this is the one place the accent has
        // to survive both appearances and a disabled state without guessing.
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: enabled ? JustRecorderPalette.accentNSColor : NSColor.secondaryLabelColor
        ])
        button.isEnabled = enabled
        button.translatesAutoresizingMaskIntoConstraints = false
        if !button.constraints.contains(where: { $0.identifier == "actionHeight" }) {
            let height = button.heightAnchor.constraint(greaterThanOrEqualToConstant: 28)
            height.identifier = "actionHeight"
            height.isActive = true
        }
    }

    func configureSwitch(_ control: NSSwitch, on: Bool, action: Selector) {
        control.state = on ? .on : .off
        control.target = self
        control.action = action
        control.translatesAutoresizingMaskIntoConstraints = false
    }

    func configurePopUp(
        _ popUp: NSPopUpButton,
        choices: [(String, Int)],
        selected: Int,
        fallbackTitle: String,
        action: Selector
    ) {
        popUp.removeAllItems()
        for (title, tag) in choices {
            popUp.addItem(withTitle: title)
            popUp.lastItem?.tag = tag
        }
        popUp.target = self
        popUp.action = action
        // Monospaced digits, so every numeral in the window sits on the same grid.
        popUp.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        popUp.translatesAutoresizingMaskIntoConstraints = false

        if !popUp.selectItem(withTag: selected) {
            // A value written straight into UserDefaults by hand. Show it rather than leave
            // an empty pop-up that would silently rewrite the user's choice on next click.
            popUp.addItem(withTitle: fallbackTitle)
            popUp.lastItem?.tag = selected
            _ = popUp.selectItem(withTag: selected)
        }
    }

    func configureTextField(_ field: NSTextField, mono: Bool, text: String) {
        field.stringValue = text
        field.font = mono
            ? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            : NSFont.systemFont(ofSize: 13)
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.delegate = self
        // ⏎ commits through the action; leaving the field commits through
        // `controlTextDidEndEditing`. Both land in the same idempotent `commit`.
        field.target = self
        field.action = #selector(fieldCommitted(_:))
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: Metrics.fieldWidth).isActive = true
    }

    func configureWarningIcon(_ imageView: NSImageView, tooltip: String?) {
        let symbol = NSImage(
            systemSymbolName: "exclamationmark.triangle.fill",
            accessibilityDescription: "Warning"
        )
        let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        imageView.image = symbol?.withSymbolConfiguration(configuration) ?? symbol
        imageView.contentTintColor = .systemOrange
        imageView.imageScaling = .scaleNone
        imageView.toolTip = tooltip
        imageView.isHidden = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
    }

    /// The prompt editor: an `NSTextView` in its own scroll view, hairline-bordered on the
    /// same wash as a result block. The text view keeps the classic autoresizing setup
    /// inside the scroll view; only the scroll view itself takes part in Auto Layout.
    func makePromptEditor() -> NSView {
        let promptScroll = NSScrollView()
        promptScroll.translatesAutoresizingMaskIntoConstraints = false
        promptScroll.hasVerticalScroller = true
        promptScroll.hasHorizontalScroller = false
        promptScroll.borderType = .lineBorder
        promptScroll.drawsBackground = true
        promptScroll.backgroundColor = JustRecorderPalette.washNSColor
        promptScroll.widthAnchor.constraint(equalToConstant: Metrics.columnWidth).isActive = true
        promptScroll.heightAnchor.constraint(equalToConstant: Metrics.promptHeight).isActive = true

        promptTextView.frame = NSRect(
            x: 0, y: 0,
            width: Metrics.columnWidth, height: Metrics.promptHeight
        )
        promptTextView.minSize = NSSize(width: 0, height: Metrics.promptHeight)
        promptTextView.maxSize = NSSize(width: 1_000_000, height: 1_000_000)
        promptTextView.isVerticallyResizable = true
        promptTextView.isHorizontallyResizable = false
        promptTextView.autoresizingMask = [.width]
        promptTextView.textContainerInset = NSSize(width: 6, height: 8)
        promptTextView.textContainer?.widthTracksTextView = true
        promptTextView.textContainer?.containerSize = NSSize(
            width: Metrics.columnWidth,
            height: 1_000_000
        )
        promptTextView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        promptTextView.textColor = .labelColor
        promptTextView.drawsBackground = false
        promptTextView.isRichText = false
        promptTextView.allowsUndo = true
        // A prompt is nearly code: smart quotes and smart dashes would quietly rewrite it.
        promptTextView.isAutomaticQuoteSubstitutionEnabled = false
        promptTextView.isAutomaticDashSubstitutionEnabled = false
        promptTextView.isAutomaticTextReplacementEnabled = false
        promptTextView.setAccessibilityLabel("AI naming instructions")
        promptTextView.delegate = self
        promptTextView.string = settings.aiSystemPrompt
        promptScroll.documentView = promptTextView

        return wrap(promptScroll, top: 6, bottom: 0)
    }

    func shortPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

// MARK: - Refreshing what is on screen

private extension SettingsPanelController {

    /// The format JustRecorder would really write. With MP3 selected and nothing installed, AAC is
    /// what lands on disk, so quoting the MP3 bitrate would promise a size that never
    /// happens — and a template containing `{format}` would preview the wrong word.
    var previewFormat: AudioFormatKind {
        (settings.format == .mp3 && mp3EncoderName == nil) ? .aac : settings.format
    }

    var sizeEstimate: String {
        let format = previewFormat
        let bitrate = format == .mp3 ? settings.mp3BitrateKbps : settings.aacBitrateKbps
        let megabytes = format.approximateMBPerMinute(
            sampleRate: settings.sampleRate,
            bitrateKbps: bitrate
        )
        return String(format: "%.1f MB per minute", megabytes)
    }

    /// Ring size: seconds × sample rate × 2 channels × 4 bytes (deinterleaved float32).
    var preRollMegabytes: String {
        let bytes = Double(settings.preRollSeconds * settings.sampleRate * 2 * 4)
        return String(format: "%.0f", (bytes / 1_048_576).rounded())
    }

    /// Only worth doing for someone who has actually chosen MP3; for everyone else it is a
    /// filesystem walk with nothing to say.
    func refreshEncoder() {
        guard settings.format == .mp3 else { return }
        MP3Transcoder.invalidateEncoderCache()
        mp3EncoderName = MP3Transcoder.locateEncoder()?.displayName
    }

    func refreshFormatSection() {
        let format = settings.format
        bitrateRow?.isHidden = format != .aac
        bitrateCaption?.isHidden = format != .aac
        mp3NoteRow?.isHidden = format != .mp3
        // The second hairline only earns its place when there is something between the two.
        formatExtraHairline?.isHidden = !(format == .aac || format == .mp3)

        if format == .mp3 {
            if let mp3EncoderName {
                mp3Warning.isHidden = true
                mp3NoteLabel.stringValue =
                    "MP3 is encoded with \(mp3EncoderName) at \(settings.mp3BitrateKbps) kbps."
            } else {
                mp3Warning.isHidden = false
                mp3NoteLabel.stringValue = """
                No MP3 encoder on this Mac, so JustRecorder records AAC instead. \
                Installing lame (brew install lame) adds one.
                """
            }
        }

        sizeLabel.stringValue = sizeEstimate
        view.needsLayout = true
    }

    func refreshPreRollSection() {
        let enabled = settings.preRollEnabled
        preRollHairline?.isHidden = !enabled
        preRollRow?.isHidden = !enabled
        preRollCaptionRow?.isHidden = !enabled
        preRollCaption.stringValue = """
        About \(preRollMegabytes) MB of memory, and the capture stream stays awake — so \
        macOS shows its recording indicator continuously. The only setting that costs \
        anything while nothing is happening.
        """
        view.needsLayout = true
    }

    /// The preview has to quote the format JustRecorder would really write and honour the title
    /// trim, otherwise the name it shows is not the name that lands on disk. It reads the
    /// *field*, not the stored template, so it keeps up with typing before the commit.
    func refreshPreview() {
        let format = previewFormat
        let name = NameTemplate.preview(
            templateField.stringValue,
            format: format.shortName,
            titleLimit: settings.maxTitleLength
        ) + "." + format.fileExtension
        previewLabel.stringValue = name
        previewLabel.toolTip = name
    }

    func refreshHotKeyField() {
        hotKeyButton.title = isListeningForHotKey
            ? "Press keys… (esc cancels)"
            : settings.hotKeyDisplayString

        // Carbon may have refused the stored combination — another app owns it. Without
        // this the field happily displayed a shortcut that never fired. The registration
        // happens in `AppDelegate` on a 250 ms debounce, so this is also re-read whenever
        // `HotKeyManager` reports back.
        let refused: Bool
        if let active = HotKeyManager.shared.activeHotKey {
            refused = Int(active.keyCode) != settings.hotKeyCode
                || active.modifiers != settings.modifierFlags
        } else {
            refused = true
        }
        hotKeyWarning.isHidden = !refused || isListeningForHotKey
    }

    func applyPermissionState(_ granted: Bool) {
        let symbol = NSImage(
            systemSymbolName: granted ? "checkmark" : "exclamationmark.triangle.fill",
            accessibilityDescription: nil
        )
        let configuration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        permissionIcon.image = symbol?.withSymbolConfiguration(configuration) ?? symbol
        permissionIcon.contentTintColor = granted ? JustRecorderPalette.accentNSColor : .systemOrange
        permissionLabel.stringValue = granted
            ? "Screen & System Audio Recording is granted."
            : "Capture access has not been confirmed for this copy."
        permissionCaptionRow?.isHidden = granted
    }

    func setResult(_ label: NSTextField, block: NSView?, text: String) {
        label.stringValue = text
        block?.isHidden = text.isEmpty
        // The block just changed the height of the whole column.
        view.needsLayout = true
    }
}

// MARK: - Actions

private extension SettingsPanelController {

    // MARK: Capture

    @objc func hotKeyButtonPressed() {
        if isListeningForHotKey { stopListeningForHotKey() } else { startListeningForHotKey() }
    }

    func startListeningForHotKey() {
        stopListeningForHotKey() // never two monitors
        isListeningForHotKey = true
        HotKeyManager.shared.isCapturingShortcut = true
        refreshHotKeyField()
        hotKeyMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self else { return event }
            guard event.type == .keyDown else {
                // A click anywhere means the user changed their mind. The click itself is
                // not ours to swallow.
                self.stopListeningForHotKey()
                return event
            }

            if event.keyCode == 53 { // esc
                self.stopListeningForHotKey()
                return nil
            }

            let flags = event.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
                .intersection([.command, .option, .control, .shift])

            guard !flags.isEmpty else {
                NSSound.beep() // a bare key would hijack normal typing
                return nil
            }

            self.settings.hotKeyCode = Int(event.keyCode)
            self.settings.hotKeyModifiers = Int(flags.rawValue)
            self.stopListeningForHotKey()
            return nil
        }
    }

    /// Every teardown path comes through here: the button again, esc, a click, the window
    /// losing key, the window closing, and `deinit` as a last resort. A monitor left armed
    /// keeps swallowing this app's key events — including the ones meant for the API-key
    /// field further down the column.
    func stopListeningForHotKey() {
        if let hotKeyMonitor { NSEvent.removeMonitor(hotKeyMonitor) }
        hotKeyMonitor = nil
        isListeningForHotKey = false
        HotKeyManager.shared.isCapturingShortcut = false
        refreshHotKeyField()
    }

    @objc func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = settings.saveFolderURL
        panel.prompt = "Use Folder"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        guard FileManager.default.isWritableFile(atPath: url.path) else {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "JustRecorder cannot save there"
            alert.informativeText =
                "“\(url.path)” is not writable, so the save folder was left unchanged."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        settings.saveFolder = url.path
        settings.ensureSaveFolderExists()
        savePathLabel.stringValue = shortPath(url.path)
        savePathLabel.toolTip = url.path
    }

    @objc func autoStopChanged(_ sender: NSPopUpButton) {
        guard let tag = sender.selectedItem?.tag else { return }
        settings.autoStopMinutes = tag
    }

    // MARK: Format

    @objc func formatChanged(_ sender: NSPopUpButton) {
        let formats = AudioFormatKind.allCases
        let index = sender.indexOfSelectedItem
        guard index >= 0, index < formats.count else { return }
        settings.format = formats[index]
        // Re-validated on every change, not once at launch: the user may have installed
        // lame/ffmpeg since, and the note, the size estimate and the `{format}` preview all
        // have to agree with what the recorder would really write.
        refreshEncoder()
        refreshFormatSection()
        refreshPreview()
    }

    @objc func bitrateChanged(_ sender: NSPopUpButton) {
        guard let tag = sender.selectedItem?.tag else { return }
        settings.aacBitrateKbps = tag
        refreshFormatSection()
    }

    // MARK: Pre-roll

    @objc func preRollToggled(_ sender: NSSwitch) {
        settings.preRollEnabled = sender.state == .on
        refreshPreRollSection()
    }

    @objc func preRollSecondsChanged(_ sender: NSPopUpButton) {
        guard let tag = sender.selectedItem?.tag else { return }
        settings.preRollSeconds = tag
        refreshPreRollSection()
    }

    // MARK: Naming

    @objc func restoreTemplate() {
        settings.nameTemplate = Settings.defaultNameTemplate
        templateField.stringValue = Settings.defaultNameTemplate
        refreshPreview()
    }

    @objc func appleScriptToggled(_ sender: NSSwitch) {
        settings.useAppleScriptMetadata = sender.state == .on
    }

    @objc func runDetection() {
        guard !isDetecting else { return }
        isDetecting = true
        setQuietTitle(detectButton, "Checking…", enabled: false)
        setResult(detectionLabel, block: detectionBlock, text: "")

        let useAppleScript = settings.useAppleScriptMetadata
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let info = SourceDetector.detectWithTimeout(useAppleScript: useAppleScript)
            let text = """
            how     \(info.method)
            app     \(info.appName.isEmpty ? "—" : info.appName)
            heard   \(info.rawWindowTitle.isEmpty ? "—" : info.rawWindowTitle)
            title   \(info.bestTitle())
            artist  \(info.artist ?? "—")
            """
            DispatchQueue.main.async {
                guard let self, !self.isClosed else { return }
                self.isDetecting = false
                self.setQuietTitle(self.detectButton, "Test detection now", enabled: true)
                self.setResult(self.detectionLabel, block: self.detectionBlock, text: text)
            }
        }
    }

    // MARK: AI

    @objc func aiToggled(_ sender: NSSwitch) {
        settings.aiEnabled = sender.state == .on
        // A key typed and then left alone while the switch is flicked is still a finished
        // edit.
        commitAPIKey()
    }

    @objc func restorePrompt() {
        settings.aiSystemPrompt = Settings.defaultAIPrompt
        promptTextView.string = Settings.defaultAIPrompt
    }

    @objc func runAITest() {
        guard !isTesting else { return }
        // The test must use — and keep — what is in the fields right now. A text view keeps
        // first responder when a borderless button is clicked, so neither of these has
        // necessarily ended editing yet.
        commitAllEdits()
        guard apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) == savedAPIKey else { return }

        isTesting = true
        setQuietTitle(aiTestButton, "Sending…", enabled: false)
        setResult(aiResultLabel, block: aiResultBlock, text: "")

        let config = LLMNamer.Config(
            baseURL: settings.aiBaseURL,
            apiKey: savedAPIKey,
            model: settings.aiModel,
            systemPrompt: settings.aiSystemPrompt,
            timeout: settings.aiTimeout
        )
        let maxLength = settings.maxTitleLength

        aiTestTask = Task { [weak self] in
            let outcome = await LLMNamer.test(config: config, maxLength: maxLength)
            // The text is built off the main thread and out of `outcome` alone, so the hop
            // back carries nothing but a string.
            guard !Task.isCancelled else { return }
            let text: String
            switch outcome {
            case .success(let title):
                text = """
                in   (3) Example Artist - Example Track (Live) Official Video - YouTube — Google Chrome
                out  \(title)
                """
            case .failure(let error):
                text = "no name came back — \(error.localizedDescription)"
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isClosed else { return }
                self.aiTestTask = nil
                self.isTesting = false
                self.setQuietTitle(self.aiTestButton, "Send a sample title", enabled: true)
                self.setResult(self.aiResultLabel, block: self.aiResultBlock, text: text)
            }
        }
    }

    // MARK: Behaviour and permission

    @objc func launchAtLoginToggled(_ sender: NSSwitch) {
        if let error = LaunchAtLogin.set(sender.state == .on) {
            setResult(behaviorResultLabel, block: behaviorResultBlock, text: "Launch at login could not be changed: \(error)")
        } else {
            let text = LaunchAtLogin.needsApproval
                ? "Allow JustRecorder in System Settings → General → Login Items to finish enabling launch at login."
                : ""
            setResult(behaviorResultLabel, block: behaviorResultBlock, text: text)
        }
        // Re-read rather than trust the write: a refused registration must not leave the
        // switch showing a state the system disagrees with.
        launchSwitch.state = LaunchAtLogin.isEnabled ? .on : .off
    }

    @objc func soundsToggled(_ sender: NSSwitch) {
        settings.playSounds = sender.state == .on
    }

    @objc func openSystemSettings() {
        ScreenRecordingPermission.openSystemSettings()
    }
}

// MARK: - Committing edits

private extension SettingsPanelController {

    /// Every commit compares before it writes, so all of these are idempotent and none of
    /// them posts a spurious change notification.
    func commitAllEdits() {
        commitTemplate()
        commitBaseURL()
        commitModel()
        commitPrompt()
        commitAPIKey()
    }

    func commitTemplate() {
        let value = templateField.stringValue
        guard value != settings.nameTemplate else { return }
        settings.nameTemplate = value
        refreshPreview()
    }

    func commitBaseURL() {
        let value = baseURLField.stringValue
        guard value != settings.aiBaseURL else { return }
        settings.aiBaseURL = value
    }

    func commitModel() {
        let value = modelField.stringValue
        guard value != settings.aiModel else { return }
        settings.aiModel = value
    }

    func commitPrompt() {
        let value = promptTextView.string
        guard value != settings.aiSystemPrompt else { return }
        settings.aiSystemPrompt = value
    }

    /// The key is written at the natural boundaries of an edit — ⏎, leaving the field, the
    /// window losing focus, the window closing — and never per keystroke, which cost a
    /// Keychain write per character. Because every one of those paths commits, a key typed
    /// into a window that is then dismissed with ⌘W is still there next time.
    func commitAPIKey() {
        let trimmed = apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        // Compared against the last written value, not against `settings.aiAPIKey`, which
        // would be a Keychain read every time.
        guard trimmed != savedAPIKey else { return }
        guard settings.saveAPIKey(trimmed) else {
            setResult(aiResultLabel, block: aiResultBlock,
                      text: "The API key could not be saved in Keychain. Unlock your login keychain and try again.")
            return
        }
        savedAPIKey = trimmed
    }

    @objc func fieldCommitted(_ sender: NSTextField) {
        commit(sender)
    }

    func commit(_ field: NSTextField) {
        if field === templateField {
            commitTemplate()
        } else if field === baseURLField {
            commitBaseURL()
        } else if field === modelField {
            commitModel()
        } else if field === apiKeyField {
            commitAPIKey()
        }
    }
}

// MARK: - Text delegates and window notifications

extension SettingsPanelController {

    @objc func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field === templateField else { return }
        // The live preview is the only thing that keeps up with typing, and it is pure
        // string work — the template parser, two regexes and the sanitiser. No I/O, and no
        // Keychain: the API-key field deliberately does nothing here.
        refreshPreview()
    }

    @objc func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        commit(field)
    }

    @objc func textDidEndEditing(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView,
              textView === promptTextView
        else { return }
        commitPrompt()
    }

    @objc fileprivate func hotKeyRegistrationChanged() {
        refreshHotKeyField()
    }

    @objc fileprivate func windowDidBecomeKey(_ note: Notification) {
        guard let window = note.object as? NSWindow, window === view.window else { return }
        // A user action, not a render: coming back to the window after a trip to Terminal
        // to install an encoder is the one input the format pop-up cannot see for itself.
        refreshEncoder()
        refreshFormatSection()
        refreshPreview()
        applyPermissionState(ScreenRecordingPermission.isGranted)
        launchSwitch.state = LaunchAtLogin.isEnabled ? .on : .off
    }

    @objc fileprivate func windowDidResignKey(_ note: Notification) {
        guard let window = note.object as? NSWindow, window === view.window else { return }
        stopListeningForHotKey()
        commitAllEdits()
    }
}
