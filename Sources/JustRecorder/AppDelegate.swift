import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    private let settings = Settings.shared
    private var menuBar: MenuBarController?

    /// The one settings observer. Nothing else observes anything, so there is no reason to
    /// keep a collection of tokens around for the life of the process.
    private var settingsObserver: NSObjectProtocol?

    private var pendingSync: DispatchWorkItem?

    private var appliedHotKey: (code: Int, modifiers: Int)?
    private var appliedPreRoll: (enabled: Bool, seconds: Int, sampleRate: Int)?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        settings.ensureSaveFolderExists()
        installApplicationMenu()
        menuBar = MenuBarController()

        HotKeyManager.shared.onTrigger = {
            RecordingController.shared.toggle()
        }

        RecordingController.shared.recoverOrphanedRecordings()
        syncFromSettings(force: true)
        observeSettings()

        showWelcomeIfNeeded()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard SettingsWindowController.shared.canTerminate() else { return .terminateCancel }
        // Nothing new may be started while we are shutting down.
        HotKeyManager.shared.unregister()
        // Termination can be held for up to three seconds below, and the run loop keeps
        // turning while it is: a debounced sync landing in that window would re-arm the
        // capture stream underneath the clip being finalised.
        stopObservingSettings()
        SettingsWindowController.shared.commitPendingEdits()

        let waiting = RecordingController.shared.finishForTermination(timeout: 3) {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return waiting ? .terminateLater : .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        HotKeyManager.shared.unregister()
        stopObservingSettings()
    }

    private func stopObservingSettings() {
        pendingSync?.cancel()
        pendingSync = nil
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
        }
        settingsObserver = nil
    }

    /// Menu-bar apps have no windows; keep running when the settings window closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Standard responder-chain editing and window shortcuts while Settings is active.
    private func installApplicationMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "JustRecorder")
        appMenu.addItem(withTitle: "Quit JustRecorder", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.mainMenu = main
    }

    // MARK: - Settings plumbing

    private func observeSettings() {
        // Debounced, and it only *compares*: the expensive part (re-arming the capture
        // stream) runs when the hotkey, the pre-roll or the sample rate actually change.
        // No timer of any kind is scheduled while nothing changes.
        settingsObserver = NotificationCenter.default.addObserver(
            forName: Settings.didChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleSync()
        }
    }

    /// Trailing-edge debounce: each change cancels the previous pending sync and books a
    /// new one 250 ms out, so a run of edits (dragging through a pop-up, holding a key)
    /// re-arms the capture stream once instead of once per keystroke.
    private func scheduleSync() {
        pendingSync?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingSync = nil
            self.syncFromSettings(force: false)
        }
        pendingSync = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func syncFromSettings(force: Bool) {
        let hotKey = (code: settings.hotKeyCode, modifiers: settings.hotKeyModifiers)
        if force || appliedHotKey == nil || appliedHotKey! != hotKey {
            let ok = HotKeyManager.shared.register(
                keyCode: UInt16(hotKey.code),
                modifiers: settings.modifierFlags
            )
            appliedHotKey = hotKey
            if !ok {
                Log.warn("Could not claim \(settings.hotKeyDisplayString) — another app may own it.")
            }
        }

        // The sample rate belongs here too: it is baked into the armed capture stream,
        // so changing it has to go through the same re-arm path as the pre-roll toggle.
        let preRoll = (
            enabled: settings.preRollEnabled,
            seconds: settings.preRollSeconds,
            sampleRate: settings.sampleRate
        )
        if force || appliedPreRoll == nil || appliedPreRoll! != preRoll {
            appliedPreRoll = preRoll
            RecordingController.shared.applyPreRollSetting()
        }

        menuBar?.refresh()
    }

    // MARK: - First run

    private func showWelcomeIfNeeded() {
        let key = "didShowWelcome"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "JustRecorder lives in your menu bar"
        alert.informativeText = """
        Press \(settings.hotKeyDisplayString) to start capturing whatever your Mac is playing, \
        press it again to save.

        Recordings go to:
        \(settings.saveFolder)

        macOS may request “Screen & System Audio Recording” when you first record — that is the permission \
        that lets JustRecorder hear system audio. Nothing is ever uploaded, and what you hear is unchanged.
        """
        alert.addButton(withTitle: "Open Capture Permissions")
        alert.addButton(withTitle: "Open Settings…")
        alert.addButton(withTitle: "Later")

        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            ScreenRecordingPermission.openSystemSettings()
        case .alertSecondButtonReturn:
            SettingsWindowController.shared.show()
        default:
            break
        }
    }
}
