import Foundation
import AppKit
// Audio-only subframework; see AudioFileWriter.swift.
import AVFAudio

/// Ties everything together: hotkey → capture → naming → file on disk.
final class RecordingController {

    static let shared = RecordingController()

    // MARK: - Observable-ish state (menu bar refreshes through `onStateChange`)

    private(set) var isRecording = false
    private(set) var lastSavedURL: URL?
    private(set) var status = RecordingStatus(message: "", needsAttention: false)
    var statusMessage: String { status.message }
    var needsAttention: Bool { status.needsAttention }

    private func updateStatus(_ message: String, needsAttention: Bool = false) {
        status = RecordingStatus(message: message, needsAttention: needsAttention)
    }

    var onStateChange: (() -> Void)?

    var currentDuration: TimeInterval { recorder.currentDuration }

    // MARK: - Private

    private let recorder = SystemAudioRecorder()
    private let settings = Settings.shared

    /// Detection task belonging to the *current* recording. Handed to `finalize` by
    /// `stop()`, never read from `finalize` itself — a new recording may already own
    /// this property by the time naming completes.
    private var sourceTask: Task<SourceInfo, Never>?

    /// `start()` only flips `isRecording` once the stream is up, so a second hotkey
    /// press in that window would otherwise start a second recording.
    private(set) var isStarting = false
    private(set) var isStopping = false

    /// Set when the hotkey is pressed *again* while `start()` is still arming: the arming
    /// task then drops out instead of leaving the user recording something they cancelled.
    private(set) var startCancelled = false

    private var armingGeneration = 0
    private var armingTimeout: DispatchWorkItem?
    private var recordingDeadline: DispatchWorkItem?
    private var captureNeedsRestart = false

    /// How long the `SCShareableContent` query + `SCStream.startCapture` may take before
    /// JustRecorder gives up. The capture subsystem can wedge indefinitely; without this the
    /// `isStarting` latch would never be released and the hotkey would be dead until
    /// the app is relaunched.
    private static let armingTimeoutSeconds: TimeInterval = 8

    /// Final target names claimed by a finalisation that has not moved its file into
    /// place yet. Consulted alongside the on-disk check so two captures of the same
    /// track finishing together cannot pick the same name (the second gets " 2").
    /// Guarded by `reservationLock`: `finalize` does not run on the main actor.
    private var reservedTargetPaths: Set<String> = []
    private let reservationLock = NSLock()

    /// Format resolved when the recording started — the user can change it while it runs.
    private var activeFormat: AudioFormatKind?

    private var pendingFinalizations = 0
    private var isTerminating = false
    private var terminationCompletion: (() -> Void)?

    private struct FinalizePlan {
        let effectiveFormat: AudioFormatKind
        let mp3BitrateKbps: Int
        let folder: URL
        let template: String
        let maxTitleLength: Int
        let aiEnabled: Bool
        let aiConfig: LLMNamer.Config?
        let revealAfterSave: Bool
    }

    private init() {
        recorder.onAutoStop = { [weak self] limitSeconds in
            // The user may have pressed stop in the same run-loop turn; the message must
            // not overwrite the "saved as …" status of a recording that already ended.
            guard let self, self.isRecording else { return }
            self.updateStatus("Auto-stopped after \(max(1, Int(limitSeconds / 60))) min.")
            self.stop()
        }
        recorder.onStreamError = { [weak self] message in
            guard let self else { return }
            if self.isRecording {
                self.stop()
                self.presentError(message)
            } else {
                // An *armed* (pre-roll) stream can die for reasons that do not deserve a
                // modal alert on top of whatever the user is doing — display sleep, the
                // permission being revoked while idle. The next `start()` re-arms it,
                // because the recorder has already dropped its reference.
                self.updateStatus(message, needsAttention: true)
                self.onStateChange?()
                Log.warn("Idle capture stream stopped: \(message)")
            }
        }
    }

    // MARK: - Lifecycle

    func applyPreRollSetting() {
        recorder.configurePreRoll(
            enabled: settings.preRollEnabled,
            seconds: settings.preRollSeconds
        )

        Task { @MainActor in
            if settings.preRollEnabled, !captureNeedsRestart {
                do {
                    try await recorder.prepareStream(sampleRate: settings.sampleRate, userInitiated: false)
                } catch {
                    updateStatus("Pre-roll is paused. Start a recording to check capture access.", needsAttention: true)
                    Log.warn("Pre-roll could not start: \(error.localizedDescription)")
                }
            } else if !isRecording, !isStarting {
                // `isStarting` matters: a settings change (or the pre-roll menu toggle)
                // landing while `start()` is still arming would otherwise tear the stream
                // down under the recording that is about to begin — no buffers would ever
                // arrive, so it could neither auto-stop nor save anything.
                await recorder.stopStream()
            }
            onStateChange?()
        }
    }

    // MARK: - Start / stop

    func toggle() {
        if isStopping { return }
        if isRecording {
            stop()
        } else if isStarting {
            // Second press while the stream is still coming up: treat it as "never mind"
            // instead of dropping the press on the floor and recording anyway.
            startCancelled = true
            updateStatus("Cancelling…")
            onStateChange?()
        } else {
            start()
        }
    }

    func start() {
        guard !isRecording, !isStarting, !isStopping, !isTerminating else { return }

        guard !captureNeedsRestart else {
            presentError("System audio capture stopped responding. Quit and reopen JustRecorder before trying again.")
            return
        }
        settings.ensureSaveFolderExists()
        guard FileManager.default.isWritableFile(atPath: settings.saveFolder) else {
            presentError("JustRecorder cannot write to “\(settings.saveFolder)”. Pick another folder in Settings.")
            return
        }

        let format = settings.effectiveFormat
        let captureExtension = format.captureFormat.fileExtension
        // The PID is part of the name so that a second JustRecorder instance's orphan sweep can
        // tell a file that is still being written from one left behind by a crash.
        let tempURL = settings.saveFolderURL
            .appendingPathComponent(
                ".justrecorder-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString.prefix(8)).\(captureExtension)"
            )

        isStarting = true
        startCancelled = false
        armingGeneration &+= 1
        let generation = armingGeneration
        updateStatus("Starting…")
        onStateChange?()
        scheduleArmingTimeout(for: generation)

        // Identify the source *now* — this is the moment the interesting audio is playing.
        // `detectAsync` keeps its blocking wait on a private queue: a `Task` thread from
        // the cooperative pool must not be parked on a semaphore.
        let useAppleScript = settings.useAppleScriptMetadata
        let detection = Task.detached(priority: .userInitiated) {
            await SourceDetector.detectAsync(useAppleScript: useAppleScript)
        }
        sourceTask = detection

        Task { @MainActor in
            do {
                try await recorder.prepareStream(sampleRate: settings.sampleRate)
            } catch {
                guard concludeArming(generation) else { return }
                detection.cancel()
                sourceTask = nil
                startCancelled = false
                presentRecorderError(error)
                return
            }

            // The arming timeout may have fired while the capture subsystem was wedged:
            // the latch is already released and the user has been told, so this late
            // success must clean up after itself instead of leaving an orphan stream
            // (and the macOS recording indicator) running.
            guard concludeArming(generation) else {
                detection.cancel()
                Log.warn("Capture stream armed after the timeout; releasing it again.")
                if !settings.preRollEnabled { await recorder.stopStream() }
                return
            }

            // A quit — or a second hotkey press — may have arrived while the stream was
            // coming up. Nothing has been written yet, so there is no file to clean up,
            // but the stream this call just armed has to be released again.
            guard !isTerminating, !startCancelled else {
                updateStatus("Cancelled.")
                detection.cancel()
                sourceTask = nil
                startCancelled = false
                if !settings.preRollEnabled { await recorder.stopStream() }
                onStateChange?()
                return
            }

            // Buffers are accepted from here on; the file itself is created lazily on the
            // writer queue when the first one lands, so nothing on this path waits for
            // the disk.
            recorder.startWriting(
                to: tempURL,
                format: format,
                bitrateKbps: settings.aacBitrateKbps,
                autoStopAfter: TimeInterval(max(0, settings.autoStopMinutes) * 60)
            )

            activeFormat = format
            isRecording = true
            recordingDeadline?.cancel()
            if settings.autoStopMinutes > 0 {
                let deadlineGeneration = armingGeneration
                let deadline = DispatchWorkItem { [weak self] in
                    guard let self, self.isRecording, self.armingGeneration == deadlineGeneration else { return }
                    self.stop()
                }
                recordingDeadline = deadline
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(settings.autoStopMinutes * 60), execute: deadline)
            }
            updateStatus("Recording…")
            onStateChange?()
            play(sound: "Tink")
        }
    }

    @discardableResult
    private func concludeArming(_ generation: Int) -> Bool {
        guard armingGeneration == generation else { return false }
        armingGeneration &+= 1
        armingTimeout?.cancel()
        armingTimeout = nil
        isStarting = false
        return true
    }

    /// Bounded arming: the `SCShareableContent` query or `SCStream.startCapture` can hang
    /// for good, and a latched `isStarting` makes the hotkey silently do nothing until
    /// the app is relaunched.
    private func scheduleArmingTimeout(for generation: Int) {
        armingTimeout?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Only the attempt that scheduled this may be timed out: a start that
            // succeeded (or failed, or was concluded any other way) has already bumped
            // the generation, so a live recording can never be killed from here.
            let wasCancelled = self.startCancelled
            guard self.concludeArming(generation) else { return }

            self.captureNeedsRestart = true
            self.startCancelled = false
            self.sourceTask?.cancel()
            self.sourceTask = nil

            // Tear down whatever half-built stream the wedged attempt may still produce.
            // The recorder serialises arm/disarm, so this teardown lands as soon as the
            // stuck call finally returns; the late-success path above covers the case
            // where it beats us to it.
            if !self.settings.preRollEnabled {
                Task { @MainActor in await self.recorder.stopStream() }
            }

            if wasCancelled {
                self.updateStatus("Cancelled.")
                self.onStateChange?()
                Log.warn("Arming timed out after a cancelled start; released the latch.")
            } else {
                self.presentError(
                    "JustRecorder couldn’t start capturing — system audio capture did not respond within "
                    + "\(Int(Self.armingTimeoutSeconds)) seconds. Quit and reopen JustRecorder to retry."
                )
            }
        }
        armingTimeout = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.armingTimeoutSeconds, execute: item)
    }

    func stop() {
        guard isRecording else { return }
        recordingDeadline?.cancel()
        recordingDeadline = nil
        isRecording = false

        // Hand the detection task over to this finalize; the next `start()` is free
        // to install its own without stealing this recording's title.
        let detection = sourceTask
        sourceTask = nil
        let format = activeFormat
        activeFormat = nil

        isStopping = true
        pendingFinalizations += 1
        updateStatus("Saving…")
        onStateChange?()
        play(sound: "Pop")
        recorder.stopWriting { [self] result in
            isStopping = false
            finishStoppedRecording(result, detection: detection, format: format)
        }
        if !settings.preRollEnabled {
            Task { @MainActor in await recorder.stopStream() }
        }
    }

    private func finishStoppedRecording(
        _ result: RecordingResult?,
        detection: Task<SourceInfo, Never>?,
        format: AudioFormatKind?
    ) {
        guard let result else {
            detection?.cancel()
            updateStatus("No audio arrived — nothing saved.", needsAttention: true)
            onStateChange?()
            Log.warn("Stopped with no writer: no audio buffers were delivered.")
            pendingFinalizations -= 1
            replyToTerminationIfIdle()
            return
        }

        guard result.duration >= 0.3 else {
            detection?.cancel()
            try? FileManager.default.removeItem(at: result.url)
            updateStatus("Too short — discarded.")
            onStateChange?()
            pendingFinalizations -= 1
            replyToTerminationIfIdle()
            return
        }

        let plan = FinalizePlan(
            effectiveFormat: format ?? settings.effectiveFormat,
            mp3BitrateKbps: settings.mp3BitrateKbps,
            // The folder the clip is *in*, not whatever Settings points at now: the user
            // may have changed it mid-recording, and a rename inside one directory cannot
            // half-fail the way a cross-volume move can.
            folder: result.url.deletingLastPathComponent(),
            template: settings.nameTemplate,
            maxTitleLength: settings.maxTitleLength,
            // Quitting must not wait on a network round-trip.
            aiEnabled: settings.aiEnabled && !isTerminating,
            aiConfig: settings.aiEnabled && !isTerminating ? .current() : nil,
            revealAfterSave: settings.revealAfterSave
        )

        updateStatus(plan.aiEnabled ? "Naming…" : "Saving…")
        onStateChange?()

        Task { await finalize(result: result, detection: detection, plan: plan) }
    }

    // MARK: - Finalisation

    private func finalize(
        result: RecordingResult,
        detection: Task<SourceInfo, Never>?,
        plan: FinalizePlan
    ) async {
        let source = await detection?.value ?? SourceInfo.unknown

        let durationText = DurationFormatter.compact(result.duration)

        // 1. Optional AI polish. Any failure falls back to the heuristic title.
        var aiTitle: String?
        if plan.aiEnabled, let aiConfig = plan.aiConfig {
            do {
                aiTitle = try await LLMNamer.suggestTitle(
                    source: source,
                    durationText: durationText,
                    config: aiConfig,
                    maxLength: plan.maxTitleLength
                )
            } catch {
                Log.warn("AI naming failed, using the local title: \(error.localizedDescription)")
            }
        }

        // 2. MP3 needs an external encoder; fall back to the captured WAV if it fails.
        let produced: (url: URL, format: AudioFormatKind)
        if plan.effectiveFormat == .mp3,
           let mp3URL = await MP3Transcoder.transcode(wavURL: result.url, bitrateKbps: plan.mp3BitrateKbps) {
            produced = (mp3URL, .mp3)
        } else if plan.effectiveFormat == .mp3 {
            // Whatever the capture actually went into — kept in step with
            // `AudioFormatKind.captureFormat` instead of hard-coded.
            produced = (result.url, plan.effectiveFormat.captureFormat)
            Log.warn("MP3 encoding failed; keeping the \(produced.format.shortName) file.")
        } else {
            produced = (result.url, plan.effectiveFormat)
        }

        // 3. Render the name and move the temp file into place.
        let context = makeContext(
            source: source,
            aiTitle: aiTitle,
            duration: result.duration,
            durationText: durationText,
            format: produced.format,
            maxTitleLength: plan.maxTitleLength
        )
        let baseName = NameTemplate.render(plan.template, context: context, maxLength: 150)
        let savedURL = moveIntoPlace(
            produced.url,
            folder: plan.folder,
            baseName: baseName,
            fallbackBaseName: "Snippet \(durationText)"
        )
        let tempName = produced.url.lastPathComponent

        await MainActor.run {
            self.pendingFinalizations = max(0, self.pendingFinalizations - 1)

            guard let finalURL = savedURL else {
                // Both renames failed (folder gone, volume unmounted, permissions): the
                // audio is still in the hidden temp file, and claiming it as "last saved"
                // would point “Reveal Last Recording” at an invisible file.
                self.updateStatus("Captured, but the file could not be renamed — check the save folder.", needsAttention: true)
                self.onStateChange?()
                Log.error("Recording left as \(tempName) in \(plan.folder.path).")
                self.replyToTerminationIfIdle()
                return
            }

            self.lastSavedURL = finalURL
            if !self.isRecording, !self.isStarting, !self.isStopping {
                self.updateStatus("\(finalURL.lastPathComponent) · \(durationText)")
            }
            self.onStateChange?()

            // Neither of these may run while the app is quitting: a modal alert would
            // hold the termination reply open until someone clicked it.
            if plan.revealAfterSave, !self.isTerminating {
                NSWorkspace.shared.activateFileViewerSelecting([finalURL])
            }
            if result.isEffectivelySilent, !self.isTerminating {
                self.warnAboutSilenceOnce()
            }
            Log.info("Saved \(finalURL.lastPathComponent) (\(durationText), source: \(source.method)).")
            self.replyToTerminationIfIdle()
        }
    }

    /// Renames the temp file to its final name, or `nil` when even the neutral fallback
    /// name could not be used.
    private func moveIntoPlace(
        _ producedURL: URL,
        folder: URL,
        baseName: String,
        fallbackBaseName: String
    ) -> URL? {
        let ext = producedURL.pathExtension
        let destination = claimTarget(in: folder, baseName: baseName, extension: ext)
        do {
            try FileManager.default.moveItem(at: producedURL, to: destination)
            // The file itself now holds the name, so the on-disk check covers it.
            releaseTarget(destination)
            return destination
        } catch {
            releaseTarget(destination)
            Log.error("Could not rename the recording: \(error.localizedDescription)")
        }
        // Leaving the clip as a hidden temp file would make the next launch treat it as
        // an orphan, so try once more with a neutral name.
        let fallback = claimTarget(in: folder, baseName: fallbackBaseName, extension: ext)
        defer { releaseTarget(fallback) }
        if (try? FileManager.default.moveItem(at: producedURL, to: fallback)) != nil {
            return fallback
        }
        return nil
    }

    private func makeContext(
        source: SourceInfo,
        aiTitle: String?,
        duration: TimeInterval,
        durationText: String,
        format: AudioFormatKind,
        maxTitleLength: Int
    ) -> NameContext {
        let heuristicTitle = FilenameSanitizer.sanitize(
            source.bestTitle(fallback: "Snippet"),
            maxLength: maxTitleLength
        )
        let title = (aiTitle?.isEmpty == false) ? aiTitle! : heuristicTitle

        let now = Date()
        let (dateText, timeText) = Self.dateAndTimeText(for: now)

        return NameContext(
            title: title,
            rawTitle: FilenameSanitizer.sanitize(source.rawWindowTitle, maxLength: maxTitleLength),
            app: FilenameSanitizer.sanitize(source.appName, maxLength: 40),
            artist: FilenameSanitizer.sanitize(source.artist ?? "", maxLength: 40),
            track: FilenameSanitizer.sanitize(source.track ?? "", maxLength: maxTitleLength),
            duration: durationText,
            seconds: "\(max(0, Int(duration.rounded())))",
            date: dateText,
            time: timeText,
            datetime: "\(dateText) \(timeText)",
            format: format.shortName
        )
    }

    /// Local calendar and time, using ASCII digits suitable for filenames.
    private static func dateAndTimeText(for date: Date) -> (date: String, time: String) {
        let parts = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        func pad(_ value: Int?, width: Int) -> String {
            var text = String(max(0, value ?? 0))
            while text.count < width { text = "0" + text }
            return text
        }
        return (
            "\(pad(parts.year, width: 4))-\(pad(parts.month, width: 2))-\(pad(parts.day, width: 2))",
            "\(pad(parts.hour, width: 2))-\(pad(parts.minute, width: 2))-\(pad(parts.second, width: 2))"
        )
    }

    /// Picks a free name **and reserves it** so that a concurrent finalisation computing
    /// the same base name gets the next suffix instead of the same target. Callable from
    /// any thread; every caller must hand the name back with `releaseTarget(_:)` once the
    /// move has succeeded or failed.
    private func claimTarget(in folder: URL, baseName: String, extension ext: String) -> URL {
        reservationLock.lock()
        defer { reservationLock.unlock() }
        let url = uniqueURL(in: folder, baseName: baseName, extension: ext, avoiding: reservedTargetPaths)
        reservedTargetPaths.insert(url.path)
        return url
    }

    private func releaseTarget(_ url: URL) {
        reservationLock.lock()
        reservedTargetPaths.remove(url.path)
        reservationLock.unlock()
    }

    private func uniqueURL(
        in folder: URL,
        baseName: String,
        extension ext: String,
        avoiding reserved: Set<String>
    ) -> URL {
        let fileManager = FileManager.default
        func isTaken(_ url: URL) -> Bool {
            fileManager.fileExists(atPath: url.path) || reserved.contains(url.path)
        }
        var candidate = folder.appendingPathComponent(baseName).appendingPathExtension(ext)
        var counter = 2
        while isTaken(candidate) {
            guard counter < 1000 else {
                // Do not hand back a name that is known to exist — `moveItem` would fail
                // and the clip would be left behind as a hidden temp file.
                return folder
                    .appendingPathComponent("\(baseName) \(UUID().uuidString.prefix(6))")
                    .appendingPathExtension(ext)
            }
            candidate = folder
                .appendingPathComponent("\(baseName) \(counter)")
                .appendingPathExtension(ext)
            counter += 1
        }
        return candidate
    }

    // MARK: - Recovery

    /// Prefix of temp files written by this build, and the one used by the pre-rename
    /// build so its interrupted recordings are recovered as well.
    private static let tempFilePrefix = ".justrecorder-"
    private static let legacyTempFilePrefix = ".riff-"

    /// Renames leftover hidden temp files (from a crash or a quit mid-recording).
    func recoverOrphanedRecordings() {
        let folder = settings.saveFolderURL
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.sweepOrphanedRecordings(in: folder)
        }
    }

    /// Files that another *running* JustRecorder is still writing are left alone: renaming (or
    /// deleting, because a file still open for writing often reads back as zero length)
    /// the live capture of a second instance would destroy it.
    private func sweepOrphanedRecordings(in folder: URL) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil
        ) else { return }

        for url in entries where Self.isTempRecording(url) {
            if isBeingWrittenByAnotherInstance(url) {
                Log.info("Leaving \(url.lastPathComponent) alone: another JustRecorder instance is writing it.")
                continue
            }
            var durationText = "unknown"
            if let file = try? AVAudioFile(forReading: url), file.fileFormat.sampleRate > 0 {
                let seconds = Double(file.length) / file.fileFormat.sampleRate
                if seconds < 0.3 {
                    try? FileManager.default.removeItem(at: url)
                    continue
                }
                durationText = DurationFormatter.compact(seconds)
            }
            let destination = claimTarget(
                in: folder,
                baseName: "Recovered Snippet \(durationText)",
                extension: url.pathExtension
            )
            if (try? FileManager.default.moveItem(at: url, to: destination)) != nil {
                Log.info("Recovered \(destination.lastPathComponent).")
            } else {
                Log.warn("Could not recover \(url.lastPathComponent); leaving it in place.")
            }
            releaseTarget(destination)
        }
    }

    private static func isTempRecording(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return name.hasPrefix(tempFilePrefix) || name.hasPrefix(legacyTempFilePrefix)
    }

    private static func tempPrefix(for name: String) -> String? {
        for prefix in [tempFilePrefix, legacyTempFilePrefix] where name.hasPrefix(prefix) {
            return prefix
        }
        return nil
    }

    /// Temp names look like `.<app>-<pid>-<random>.<ext>`; a file whose PID still belongs
    /// to a live JustRecorder process is in use. Names without a PID (written by an older build)
    /// are treated as orphans, as before.
    private func isBeingWrittenByAnotherInstance(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        guard let prefix = Self.tempPrefix(for: name) else { return false }
        let stem = name.dropFirst(prefix.count)
        guard let separator = stem.firstIndex(of: "-"),
              let pid = pid_t(stem[stem.startIndex..<separator]),
              pid > 0
        else { return false }
        // Recovery runs concurrently with the first recording of this launch.
        if pid == ProcessInfo.processInfo.processIdentifier { return true }
        guard let other = NSRunningApplication(processIdentifier: pid),
              !other.isTerminated
        else { return false }

        if let ours = Bundle.main.bundleIdentifier, let theirs = other.bundleIdentifier {
            return ours == theirs
        }
        // Running the executable directly (no bundle identifier): compare binaries.
        return other.executableURL == Bundle.main.executableURL
    }

    // MARK: - Termination

    /// Called from `applicationShouldTerminate`.
    func finishForTermination(timeout: TimeInterval = 3, completion: @escaping () -> Void) -> Bool {
        isTerminating = true
        if isRecording { stop() }

        guard pendingFinalizations > 0 else { return false }

        var replied = false
        let reply: () -> Void = {
            guard !replied else { return }
            replied = true
            completion()
        }
        terminationCompletion = reply

        // Hard cap: a stuck transcode or detection must never wedge the quit.
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.1, timeout)) { [weak self] in
            self?.terminationCompletion = nil
            reply()
        }
        return true
    }

    /// Main queue only.
    private func replyToTerminationIfIdle() {
        guard pendingFinalizations == 0, let reply = terminationCompletion else { return }
        terminationCompletion = nil
        reply()
    }

    // MARK: - Feedback

    private func play(sound name: String) {
        guard settings.playSounds, let sound = NSSound(named: name) else { return }
        sound.volume = 0.35
        sound.play()
    }

    /// - Parameter needsPermission: adds the “Open System Settings” shortcut. Passed
    ///   explicitly rather than sniffed out of the (localisable) message text.
    func presentError(_ message: String, needsPermission: Bool = false) {
        updateStatus(message, needsAttention: true)
        onStateChange?()

        // A modal alert during shutdown would sit there unanswered while the termination
        // reply is on a 3 s fuse — the app would quit out from under it.
        guard !isTerminating else {
            Log.error("Suppressed an error alert while quitting: \(message)")
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "JustRecorder couldn’t record"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")

        if needsPermission {
            alert.addButton(withTitle: "Open System Settings")
        }

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn, needsPermission {
            ScreenRecordingPermission.openSystemSettings()
        }
    }

    private func presentRecorderError(_ error: Error) {
        presentError(error.localizedDescription, needsPermission: Self.isPermissionError(error))
    }

    private static func isPermissionError(_ error: Error) -> Bool {
        guard let recorderError = error as? RecorderError else { return false }
        if case .permissionDenied = recorderError { return true }
        return false
    }

    private func warnAboutSilenceOnce() {
        let key = "didWarnAboutSilence"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "That recording looks silent"
        alert.informativeText = """
        The file was saved, but no sound was detected.

        Two things to check:
        • Something was actually playing through your Mac's output (not a Bluetooth headset paired to your phone).
        • JustRecorder is enabled under System Settings → Privacy & Security → Screen & System Audio Recording. \
        After granting it, quit and reopen JustRecorder.

        This notice is only shown once.
        """
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Open System Settings")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn {
            ScreenRecordingPermission.openSystemSettings()
        }
    }
}
