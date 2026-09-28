import AppKit

/// JustRecorder's entire visible surface: one status-bar item and its menu.
final class MenuBarController: NSObject, NSMenuDelegate {

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let controller = RecordingController.shared
    private let settings = Settings.shared
    private let menu = NSMenu()
    private var timer: Timer?

    /// What the status item is currently showing. Used to keep the glyph crossfade and the
    /// accessibility label to real state changes instead of every half-second tick.
    private var shownPresence: Presence?

    /// The primary (record/stop) item of the menu as currently built. `NSMenu` does not
    /// rebuild an open menu, so without this the elapsed time froze the moment the menu
    /// appeared — and an auto-stop landing while the menu was open left the item still
    /// offering to stop a recording that had already been saved.
    private weak var primaryItem: NSMenuItem?

    /// The caption line under the primary item, for the same reason: the status text
    /// changes while the menu is open ("Naming…" → the saved file name), and an
    /// auto-stop can make it appear or disappear from under an open menu.
    private weak var captionItem: NSMenuItem?
    private weak var revealItem: NSMenuItem?

    private var menuIsOpen = false

    /// The status glyphs, built once. `refresh()` runs twice a second while recording and
    /// `NSImage(systemSymbolName:)` allocates and re-renders on every call.
    private var symbolCache: [String: NSImage] = [:]

    /// Menu-bar point size for the mark: large enough to read instantly at a glance in
    /// either appearance, small enough to stay a quiet presence.
    private static let glyphConfiguration = NSImage.SymbolConfiguration(
        pointSize: 16,
        weight: .regular,
        scale: .small
    )

    /// Monospaced digits at the menu-bar font size: "0:09" → "0:10" must not change the
    /// width of the status item.
    private static let timerFont = NSFont.monospacedDigitSystemFont(
        ofSize: NSFont.menuBarFont(ofSize: 0).pointSize,
        weight: .regular
    )

    override init() {
        super.init()

        menu.appearance = nil
        menu.delegate = self
        // JustRecorder enables/disables its own items (e.g. "Reveal last recording"); automatic
        // enabling would override that, because every item has a valid target/action.
        menu.autoenablesItems = false
        // A calm, constant menu width: without it the menu grew and shrank around the
        // elapsed time and the status caption.
        menu.minimumWidth = 248
        statusItem.menu = menu
        statusItem.behavior = .terminationOnRemoval

        controller.onStateChange = { [weak self] in
            DispatchQueue.main.async { self?.refresh() }
        }

        refresh()
    }

    deinit {
        timer?.invalidate()
    }

    // MARK: - State

    /// Recording lifecycle and attention states.
    private enum Presence {
        case idle
        case starting
        case recording
        case saving
        /// Something went wrong and the user has not started anything since.
        case attention
    }

    private var presence: Presence {
        if controller.isRecording { return .recording }
        // The window where the capture stream is coming up: the hotkey (and the menu)
        // cancel rather than start during it, so the mark must not read as idle.
        if controller.isStarting { return .starting }
        if controller.isStopping { return .saving }
        return controller.needsAttention ? .attention : .idle
    }

    // MARK: - Appearance

    func refresh() {
        guard let button = statusItem.button else { return }

        let presence = self.presence
        let hasGlyph = applyGlyph(for: presence, to: button)
        applyTitle(recording: presence == .recording, hasGlyph: hasGlyph, to: button)
        button.toolTip = tooltip(for: presence)
        button.setAccessibilityLabel(accessibilityLabel(for: presence))

        updateTimer(active: presence == .recording && (settings.showTimerInMenuBar || menuIsOpen))
        refreshOpenMenu()
    }

    /// Returns whether the item ended up with a glyph — see `applyTitle`.
    private func applyGlyph(for presence: Presence, to button: NSStatusBarButton) -> Bool {
        let image = glyph(for: presence)
        let tint: NSColor? = nil
        let changed = shownPresence != presence

        // Same cached object between ticks, so the status item is not asked to redraw the
        // symbol twice a second while recording.
        if button.image !== image { button.image = image }
        if button.contentTintColor != tint { button.contentTintColor = tint }

        if changed {
            shownPresence = presence
            button.setAccessibilityLabel(accessibilityLabel(for: presence))

            // A single short crossfade on a real state change. Nothing animates while
            // idle, nothing is delayed by it: the new mark is already in place and only
            // its opacity catches up.
            button.layer?.removeAllAnimations()
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                button.alphaValue = 1
            } else {
                button.alphaValue = 0.35
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.16
                    button.animator().alphaValue = 1
                }
            }
        }
        return image != nil
    }

    private func applyTitle(recording: Bool, hasGlyph: Bool, to button: NSStatusBarButton) {
        var text = ""
        // No SF Symbol at all (a stripped system, a future rename): an item with neither
        // image nor title is an invisible, unclickable gap in the menu bar.
        if !hasGlyph { text = "JustRecorder" }
        if recording, settings.showTimerInMenuBar {
            // Hair-thin gap, not a full space: the item has to stay narrow.
            text += "\u{2009}" + DurationFormatter.clock(controller.currentDuration)
        }

        // `imageOnly` while there is no text keeps the item at its narrowest.
        let position: NSControl.ImagePosition = text.isEmpty ? .imageOnly : .imageLeading
        if button.imagePosition != position { button.imagePosition = position }

        guard button.attributedTitle.string != text else { return }
        button.attributedTitle = NSAttributedString(
            string: text,
            attributes: [
                // Monospaced digits: "0:09" → "0:10" must not change the item's width.
                .font: MenuBarController.timerFont
            ]
        )
    }

    /// Deliberately duration-free: the refresh timer is not guaranteed to be running (it
    /// is off when both the menu-bar timer and the menu are), and a stale duration in a
    /// tooltip is worse than none.
    private func tooltip(for presence: Presence) -> String {
        let hotKey = settings.hotKeyDisplayString
        switch presence {
        case .recording:
            return "JustRecorder — recording. Press \(hotKey) to stop and save."
        case .starting:
            return controller.startCancelled ? "JustRecorder — cancelling the capture." : "JustRecorder — starting the capture. Press \(hotKey) to cancel."
        case .saving:
            return "JustRecorder — saving. Waiting for audio to finish writing."
        case .attention:
            return "JustRecorder — \(controller.statusMessage)"
        case .idle:
            return controller.statusMessage.isEmpty
                ? "JustRecorder — press \(hotKey) to capture what your Mac is playing."
                : "JustRecorder — \(controller.statusMessage)"
        }
    }

    private func accessibilityLabel(for presence: Presence) -> String {
        switch presence {
        case .idle: return "JustRecorder"
        case .starting: return controller.startCancelled ? "JustRecorder, cancelling" : "JustRecorder, starting"
        case .saving: return "JustRecorder, saving"
        case .recording: return "JustRecorder, recording"
        case .attention: return "JustRecorder, needs attention"
        }
    }

    private func glyph(for presence: Presence) -> NSImage? {
        switch presence {
        case .idle:
            return symbol("waveform")
        case .starting:
            return symbol("waveform.circle", fallback: "waveform")
        case .recording:
            return symbol("waveform.circle.fill", fallback: "waveform")
        case .saving:
            return symbol("square.and.arrow.down", fallback: "waveform")
        case .attention:
            return symbol("waveform.slash", fallback: "waveform")
        }
    }

    /// Template images inherit system menu-bar colors in every appearance.
    private func symbol(_ name: String, fallback: String? = nil) -> NSImage? {
        if let cached = symbolCache[name] { return cached }
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: "JustRecorder") else {
            // Not every symbol exists on every macOS 13 point release; the bare waveform
            // is old enough to be safe, and a marked-up shape is better than no icon.
            return fallback.flatMap { symbol($0) }
        }
        image.isTemplate = true
        let sized = image.withSymbolConfiguration(MenuBarController.glyphConfiguration) ?? image
        sized.isTemplate = true
        symbolCache[name] = sized
        return sized
    }

    private func updateTimer(active: Bool) {
        if active, timer == nil {
            let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                self?.refresh()
            }
            // A clock that is allowed to be 100 ms late lets the kernel coalesce this
            // wakeup with others instead of waking the CPU on its own schedule.
            timer.tolerance = 0.1
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else if !active, let timer {
            timer.invalidate()
            self.timer = nil
        }
    }

    // MARK: - Menu

    /// One definition of the primary item's wording, used both when the menu is built and
    /// while it is open.
    private var primaryTitle: String {
        if controller.isRecording { return "Stop and save" }
        // While arming, a second press cancels — "Start recording" would be a lie.
        if controller.startCancelled && controller.isStarting { return "Cancelling…" }
        if controller.isStarting { return "Cancel start" }
        if controller.isStopping { return "Saving…" }
        return "Start recording"
    }

    /// The quiet detail on the right of the primary item: the elapsed time while
    /// recording, the global shortcut otherwise. One slot, so the item stays calm.
    private var primaryDetail: String {
        if controller.isStopping || controller.startCancelled && controller.isStarting { return "" }
        return controller.isRecording
            ? DurationFormatter.clock(controller.currentDuration)
            : settings.hotKeyDisplayString
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        captionItem = nil

        let primary = NSMenuItem(title: primaryTitle, action: #selector(toggleRecording), keyEquivalent: "")
        primary.target = self
        menu.addItem(primary)
        primaryItem = primary
        stylePrimaryItem()

        if !controller.statusMessage.isEmpty {
            let caption = makeCaptionItem(controller.statusMessage)
            menu.addItem(caption)
            captionItem = caption
        }

        menu.addItem(.separator())

        let revealItem = NSMenuItem(title: "Reveal last recording", action: #selector(revealLast), keyEquivalent: "")
        revealItem.target = self
        // No `fileExists` here: building a menu must not touch the filesystem. The action
        // checks, and opens the folder instead if the clip has since been moved or trashed.
        revealItem.isEnabled = controller.lastSavedURL != nil
        revealItem.toolTip = controller.lastSavedURL?.path
        menu.addItem(revealItem)
        self.revealItem = revealItem

        let openFolderItem = NSMenuItem(title: "Open save folder", action: #selector(openFolder), keyEquivalent: "")
        openFolderItem.target = self
        menu.addItem(openFolderItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let quitItem = NSMenuItem(title: "Quit JustRecorder", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        // The elapsed time in the open menu has to tick even when the menu-bar timer
        // itself is switched off.
        refresh()
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        primaryItem = nil
        captionItem = nil
        revealItem = nil
        refresh()
    }

    /// Keeps an already-open menu in step with the state the status item is showing.
    private func refreshOpenMenu() {
        guard menuIsOpen else { return }
        stylePrimaryItem()
        revealItem?.isEnabled = controller.lastSavedURL != nil
        revealItem?.toolTip = controller.lastSavedURL?.path

        let message = controller.statusMessage
        if message.isEmpty {
            if let captionItem, menu.index(of: captionItem) >= 0 {
                menu.removeItem(captionItem)
            }
            captionItem = nil
        } else if let captionItem {
            // Both, so `title` never disagrees with what is drawn.
            captionItem.title = controller.status.menuCaption
            captionItem.attributedTitle = captionText(controller.status.menuCaption)
            captionItem.toolTip = message
        } else if let primaryItem, menu.index(of: primaryItem) >= 0 {
            let caption = makeCaptionItem(message)
            menu.insertItem(caption, at: menu.index(of: primaryItem) + 1)
            captionItem = caption
        }
    }

    /// Draws the primary item as `title` plus one quiet trailing detail.
    private func stylePrimaryItem() {
        guard let item = primaryItem else { return }
        item.isEnabled = !controller.isStopping && !(controller.isStarting && controller.startCancelled)
        let title = primaryTitle
        let detail = primaryDetail
        item.title = detail.isEmpty ? title : "\(title)   \(detail)"

        let styled = NSMutableAttributedString(
            string: title,
            attributes: [.font: NSFont.menuFont(ofSize: 0)]
        )
        styled.append(NSAttributedString(
            string: detail.isEmpty ? "" : "   " + detail,
            attributes: [
                // Monospaced digits so the elapsed time does not shuffle the layout of an
                // open menu either.
                .font: MenuBarController.timerFont
            ]
        ))
        item.attributedTitle = styled
    }

    private func makeCaptionItem(_ message: String) -> NSMenuItem {
        let caption = controller.status.menuCaption
        let item = NSMenuItem(title: caption, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.toolTip = message
        item.attributedTitle = captionText(caption)
        return item
    }

    private func captionText(_ message: String) -> NSAttributedString {
        NSAttributedString(
            string: message,
            attributes: [
                .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize)
            ]
        )
    }

    // MARK: - Actions

    @objc private func toggleRecording() {
        controller.toggle()
    }

    @objc private func revealLast() {
        guard let url = controller.lastSavedURL,
              FileManager.default.fileExists(atPath: url.path)
        else {
            // The clip was moved or deleted; the folder is the next most useful thing.
            openFolder()
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func openFolder() {
        settings.ensureSaveFolderExists()
        NSWorkspace.shared.open(settings.saveFolderURL)
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
