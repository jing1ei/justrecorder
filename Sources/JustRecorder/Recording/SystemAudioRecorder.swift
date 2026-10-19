import Foundation
import AppKit
// Audio-only subframework; see AudioFileWriter.swift.
import AVFAudio
import CoreGraphics
import CoreMedia
import ScreenCaptureKit

struct RecordingResult {
    let url: URL
    let duration: TimeInterval
    /// Nothing ever rose above `AudioFileWriter.silenceFloor` — almost certainly nothing
    /// was playing. Decided while writing, so no buffer is scanned twice (and none at all
    /// once the recording has been heard to make a sound).
    let isEffectivelySilent: Bool
}

enum RecorderError: LocalizedError {
    case permissionDenied
    case noDisplay
    case streamFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "macOS did not authorize this copy of JustRecorder. If the switch is already on, quit all copies and reopen the installed app. If a rebuilt app is still denied, remove its old entry in Screen & System Audio Recording, add the installed app again, then reopen it."
        case .noDisplay:
            return "No display available to attach the audio capture stream to."
        case .streamFailed(let message):
            return message
        }
    }
}

enum ScreenRecordingPermission {
    private static var state = CapturePermissionState()
    static var isGranted: Bool { !state.denied && (state.captureConfirmed || CGPreflightScreenCaptureAccess()) }

    static func canAttempt(userInitiated: Bool) -> Bool {
        state.canAttempt(preflightGranted: CGPreflightScreenCaptureAccess(), userInitiated: userInitiated)
    }
    static func didStart() { state.didStart() }
    static func didDeny() { state.didDeny() }

    static func captureError(_ error: Error) -> Error {
        let nsError = error as NSError
        if nsError.domain == SCStreamErrorDomain && nsError.code == SCStreamError.Code.userDeclined.rawValue {
            didDeny()
            return RecorderError.permissionDenied
        }
        return RecorderError.streamFailed(error.localizedDescription)
    }

    static func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }
}

/// Captures *everything the Mac plays* (browsers, players, any app) via ScreenCaptureKit.
/// Threading: the ScreenCaptureKit sample handler (`queue`) only ever copies the sample
/// buffer, feeds the pre-roll ring and hands the copy to `writerQueue`. Every blocking
/// operation — creating the file, encoding, converting, closing — happens on
/// `writerQueue`. See the state sections below for who owns what.
final class SystemAudioRecorder: NSObject, SCStreamOutput, SCStreamDelegate {

    // MARK: - Callbacks (main queue)

    /// Fired once per recording when the auto-stop limit is reached. The parameter is the
    /// limit the recording actually started with, so the message cannot quote a value the
    /// user changed halfway through.
    var onAutoStop: ((TimeInterval) -> Void)?
    var onStreamError: ((String) -> Void)?

    // MARK: - Private state

    /// Sample-handler queue. ScreenCaptureKit delivers buffers here, and it owns the
    /// callback-side session state below. **Nothing on this queue may touch the disk.**
    private let queue = DispatchQueue(label: "com.jing1ei.JustRecorder.audio", qos: .userInitiated)

    /// Serial queue that exclusively owns `writer` — file creation, every `write`, every
    /// conversion and the close. The capture callback only ever `async`s onto it, so a
    /// slow disk (or a burst of pre-roll to encode) can never back up into ScreenCapture-
    /// Kit's shallow buffer queue and cost us live audio.
    private let writerQueue: DispatchQueue

    /// Main-thread only.
    private var stream: SCStream?
    /// Queued arm/disarm work. Every request chains onto whatever is already queued, so
    /// two overlapping callers can never build (or tear down) a stream at the same time
    /// (main-thread only).
    private var preparation: Task<Void, Error>?
    /// Sample rate `stream` was actually started with (main-thread only).
    private var runningSampleRate = 0

    // Capture-queue state: written on `queue`, and from the main thread only inside a
    // `queue.sync` (all of those blocks are trivial — no I/O, no waiting).
    private var preRoll: PreRollBuffer?
    private var isWriting = false
    private var recordingID = UUID()
    /// Whether the writer-creation job for the current recording has been dispatched.
    private var didOpenWriter = false
    /// Backlog cap for the current recording, in frames (see `maxPendingSeconds`).
    private var maxPendingFrames: Int64 = 0
    /// Reused so the callback does not build an `AVAudioFormat` per buffer. Dropped with
    /// the stream, so an idle JustRecorder retains nothing from the last capture.
    private var captureFormatCache: AVAudioFormat?

    private var pendingURL: URL?
    private var pendingFormat: AudioFormatKind = .aac
    private var pendingBitrateKbps = 256
    private var autoStopSeconds: TimeInterval = 0

    // Writer-queue state: touched only from `writerQueue`.
    private var writer: AudioFileWriter?
    private var writerSessionID = UUID()
    private var activeAutoStopSeconds: TimeInterval = 0
    private var autoStopFired = false
    private var writeFailed = false

    // Shared counters, guarded by `stateLock`. The lock is only ever held for a handful
    // of scalar assignments — never across a write, an allocation or a log call.
    private let stateLock = NSLock()
    private var pendingFrames: Int64 = 0
    private var droppedFrames: Int64 = 0
    private var writtenFrames: AVAudioFramePosition = 0
    private var writtenSampleRate: Double = 0

    /// Channel count every stream is configured with. Not a setting: nothing in JustRecorder
    /// records anything but stereo, and the capture format is whatever ScreenCaptureKit
    /// then delivers.
    private static let channelCount = 2

    /// How much live audio may sit un-written ahead of the writer queue before buffers
    /// are dropped. At 48 kHz stereo float32 this is ~3.8 MB — enough to ride out a
    /// stalled disk (or the pre-roll burst at the start) without letting a permanently
    /// slow one grow the backlog for ever.
    private static let maxPendingSeconds: Double = 10

    init(writerQueue: DispatchQueue = DispatchQueue(label: "com.jing1ei.JustRecorder.audio.writer", qos: .userInitiated)) {
        self.writerQueue = writerQueue
        super.init()
    }

    // MARK: - Stream lifecycle

    /// Starts the capture stream, or restarts it when the requested configuration
    /// differs from the one it is currently running with (otherwise a sample-rate
    /// change would silently do nothing while pre-roll keeps the stream armed).
    @MainActor
    func prepareStream(sampleRate: Int, userInitiated: Bool = true) async throws {
        // Chain arm/disarm requests across asynchronous capture operations.
        let previous = preparation
        let task = Task { @MainActor in
            _ = try? await previous?.value
            try await self.startStream(sampleRate: sampleRate, userInitiated: userInitiated)
        }
        preparation = task
        defer { if preparation == task { preparation = nil } }
        try await task.value
    }

    /// Never call this directly: it runs inside the `preparation` chain, so waiting on
    /// that chain from here (or from `tearDownStream`) would deadlock.
    @MainActor
    private func startStream(sampleRate: Int, userInitiated: Bool) async throws {
        if stream != nil {
            guard sampleRate != runningSampleRate else { return }
            guard !isWritingToFile else {
                Log.info("Capture stream reconfiguration deferred: a recording is in progress.")
                return
            }
            Log.info("Reconfiguring the capture stream for \(sampleRate) Hz.")
            await tearDownStream()
        }

        guard ScreenRecordingPermission.canAttempt(userInitiated: userInitiated) else {
            throw RecorderError.permissionDenied
        }

        // Only `displays.first` is ever used, and this query is the single biggest cost
        // on the hotkey → first-sample path: asking for desktop and off-screen windows
        // makes WindowServer enumerate (and hand back the titles of) every window on the
        // system. Excluding them is the same display list for measurably less work.
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        } catch {
            throw ScreenRecordingPermission.captureError(error)
        }

        guard let display = content.displays.first else { throw RecorderError.noDisplay }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = sampleRate
        config.channelCount = Self.channelCount
        // A screen output is never attached, so these only keep the stream valid.
        config.width = 128
        config.height = 128
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        // ScreenCaptureKit's own default, and the shallowest queue it documents. Nothing
        // reads video frames here, so every slot above the minimum is an IOSurface
        // (128×128 BGRA = 64 KB) the process pays for and never looks at; audio delivery
        // is unaffected, it does not come out of this queue.
        config.queueDepth = 3
        config.showsCursor = false

        let newStream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
            try await newStream.startCapture()
        } catch {
            throw ScreenRecordingPermission.captureError(error)
        }

        ScreenRecordingPermission.didStart()
        stream = newStream
        runningSampleRate = sampleRate
        Log.info("Audio capture stream started (\(sampleRate) Hz).")
    }

    /// Disarms the capture stream (and with it the macOS recording indicator).
    @MainActor
    func stopStream() async {
        let previous = preparation
        let task: Task<Void, Error> = Task { @MainActor in
            _ = try? await previous?.value
            await self.tearDownStream()
        }
        preparation = task
        defer { if preparation == task { preparation = nil } }
        _ = try? await task.value
    }

    /// Runs inside the `preparation` chain — never waits on it.
    @MainActor
    private func tearDownStream() async {
        guard let current = stream else { return }
        // A live recording would otherwise keep running against a dead stream: no
        // buffers, no auto-stop (it is evaluated as buffers are written) and nothing
        // saved when the user finally presses stop.
        guard !isWritingToFile else {
            Log.warn("Capture stream teardown skipped: a recording is in progress.")
            return
        }
        stream = nil
        runningSampleRate = 0
        do {
            try await current.stopCapture()
        } catch {
            Log.warn("stopCapture failed: \(error.localizedDescription)")
        }
        // Idle means idle: the ring's memory and the cached capture format go with the
        // stream, so a disarmed JustRecorder holds nothing but its own code.
        queue.sync {
            preRoll?.clear()
            captureFormatCache = nil
        }
        Log.info("Audio capture stream stopped.")
    }

    // MARK: - Pre-roll

    /// The ring itself is allocated lazily by the first captured buffer and freed again
    /// when pre-roll is switched off, the stream is torn down or the ring is drained into
    /// a recording — it is never held across an idle period it is not serving.
    func configurePreRoll(enabled: Bool, seconds: Int) {
        queue.sync {
            if enabled {
                if let preRoll {
                    preRoll.setSeconds(seconds)
                } else {
                    preRoll = PreRollBuffer(seconds: seconds)
                }
            } else {
                preRoll = nil
            }
        }
    }

    // MARK: - Writing

    func startWriting(
        to url: URL,
        format: AudioFormatKind,
        bitrateKbps: Int,
        autoStopAfter: TimeInterval
    ) {
        stateLock.lock()
        pendingFrames = 0
        droppedFrames = 0
        writtenFrames = 0
        writtenSampleRate = 0
        stateLock.unlock()

        queue.sync {
            recordingID = UUID()
            pendingURL = url
            pendingFormat = format
            pendingBitrateKbps = bitrateKbps
            autoStopSeconds = autoStopAfter
            didOpenWriter = false
            maxPendingFrames = 0
            isWriting = true
        }
        // `writer`, `autoStopFired` and `writeFailed` belong to the writer queue and are
        // reset there when the file is opened — the previous recording's close is already
        // ahead of that job in the queue, so it can never clobber this one.
    }

    /// Stops accepting audio immediately. Delivers a result on the main queue only
    /// after all writes and the file close finish; an open file must never be finalized.
    func stopWriting(completion: @escaping (RecordingResult?) -> Void) {
        queue.sync {
            isWriting = false
            didOpenWriter = false
            pendingURL = nil
        }

        writerQueue.async {
            var result: RecordingResult?
            if let writer = self.writer {
                writer.close()
                result = RecordingResult(
                    url: writer.url,
                    duration: writer.duration,
                    isEffectivelySilent: !writer.didHearAudio
                )
            }
            self.writer = nil
            self.stateLock.lock()
            let rate = self.writtenSampleRate
            let dropped = self.droppedFrames
            self.stateLock.unlock()
            if dropped > 0, rate > 0 {
                Log.warn("Dropped ~\(String(format: "%.1f", Double(dropped) / rate)) s of capture: writing could not keep up.")
            }
            let closedResult = result
            DispatchQueue.main.async { completion(closedResult) }
        }
    }

    var currentDuration: TimeInterval {
        // A snapshot published by the writer queue, so the menu bar's timer never has to
        // reach into the capture queue (or wait behind a write) once a second.
        stateLock.lock()
        defer { stateLock.unlock() }
        return writtenSampleRate > 0 ? Double(writtenFrames) / writtenSampleRate : 0
    }

    /// Whether a file is currently being written. Used to avoid tearing the stream
    /// down underneath an active recording.
    private var isWritingToFile: Bool {
        queue.sync { isWriting }
    }

    // MARK: - SCStreamOutput

    /// Runs on `queue`. Cheap work only, and no allocation at all while merely armed:
    /// resolve the (cached) format, then either `memcpy` into the pre-roll ring or copy
    /// the samples out and hand them to the writer queue. Nothing here logs, builds a
    /// `String`, or touches the disk.
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        consumeAudio(sampleBuffer)
    }

    /// Capture-queue entry point, also used with synthetic audio in regression tests.
    func consumeAudio(_ sampleBuffer: CMSampleBuffer) {
        guard sampleBuffer.isValid,
              sampleBuffer.numSamples > 0,
              let format = sampleBuffer.pcmFormat(cachedFormat: &captureFormatCache)
        else { return }

        guard isWriting else {
            preRoll?.append(sampleBuffer, format: format)
            return
        }

        guard let pcmBuffer = sampleBuffer.copiedPCMBuffer(format: format),
              pcmBuffer.frameLength > 0
        else { return }

        // The pre-roll hand-off is dispatched from here, before this buffer's own write
        // job, so the ring's contents are written ahead of every live frame.
        if !didOpenWriter {
            // Only latched once the job was really dispatched: latching on an attempt that
            // bailed out would make the rest of the recording a black hole — buffers
            // accepted, no file ever opened, nothing saved.
            didOpenWriter = openWriter(matching: pcmBuffer)
        }
        enqueueForWriting(pcmBuffer)
    }

    /// Dispatches "create the file, then write the pre-roll" onto the writer queue.
    /// Called on `queue`, once per recording. Returns `false` if it could not dispatch.
    private func openWriter(matching buffer: AVAudioPCMBuffer) -> Bool {
        guard let url = pendingURL else { return false }

        let inputFormat = buffer.format
        let outputFormat = pendingFormat
        let bitrate = pendingBitrateKbps
        let autoStop = autoStopSeconds
        let rate = inputFormat.sampleRate > 0 ? inputFormat.sampleRate : 48_000
        maxPendingFrames = Int64(rate * Self.maxPendingSeconds)

        let buffered = preRoll?.drain(matching: inputFormat) ?? []
        let sessionID = recordingID

        writerQueue.async {
            self.openFile(
                at: url,
                outputFormat: outputFormat,
                bitrateKbps: bitrate,
                autoStopAfter: autoStop,
                inputFormat: inputFormat,
                preRoll: buffered,
                sessionID: sessionID
            )
        }
        return true
    }

    /// Hands `buffer` to the writer queue, or drops it when the backlog is already at the
    /// cap. Called on `queue`.
    private func enqueueForWriting(_ buffer: AVAudioPCMBuffer) {
        let frames = Int64(buffer.frameLength)

        stateLock.lock()
        let accepted = maxPendingFrames <= 0 || pendingFrames + frames <= maxPendingFrames
        if accepted {
            pendingFrames += frames
        } else {
            // Counted, not logged: the total is reported once by `stopWriting`, and a log
            // call (with the `String` it needs) is work this callback cannot afford.
            droppedFrames += frames
        }
        stateLock.unlock()

        guard accepted else { return }

        writerQueue.async { self.writeBuffer(buffer, frames: frames) }
    }

    // MARK: - Writer queue

    /// Creates the output file and writes the pre-roll into it. Writer queue only.
    private func openFile(
        at url: URL,
        outputFormat: AudioFormatKind,
        bitrateKbps: Int,
        autoStopAfter: TimeInterval,
        inputFormat: AVAudioFormat,
        preRoll buffered: [AVAudioPCMBuffer],
        sessionID: UUID
    ) {
        writerSessionID = sessionID
        autoStopFired = false
        writeFailed = false
        activeAutoStopSeconds = autoStopAfter

        let captureFormat = outputFormat.captureFormat
        let settings = captureFormat.writerSettings(
            sampleRate: inputFormat.sampleRate,
            channels: inputFormat.channelCount,
            aacBitrateKbps: bitrateKbps
        )

        let newWriter: AudioFileWriter
        do {
            newWriter = try AudioFileWriter(url: url, settings: settings, sampleRate: inputFormat.sampleRate)
        } catch {
            let message = error.localizedDescription
            Log.error("Could not create output file: \(message)")
            reportWriteFailure("Could not create the recording file: \(message)", sessionID: sessionID)
            return
        }
        writer = newWriter

        // Pre-roll that still does not match the file's format is converted (or dropped)
        // by the writer, because `AVAudioFile.write(from:)` raises an uncatchable ObjC
        // exception on a format it does not expect.
        var rejected = 0
        for buffer in buffered {
            do {
                try newWriter.write(buffer)
            } catch {
                rejected += 1
            }
        }
        let preRollSeconds = newWriter.sampleRate > 0
            ? Double(newWriter.framesWritten) / newWriter.sampleRate
            : 0
        if rejected > 0 {
            Log.warn("Skipped \(rejected) pre-roll buffer(s) the output file rejected.")
        }
        if preRollSeconds > 0 {
            Log.info("Pre-roll contributed \(String(format: "%.1f", preRollSeconds)) s.")
        } else if !buffered.isEmpty {
            Log.warn("Pre-roll was dropped: the output file accepted none of it.")
        }

        publishProgress(newWriter)
        evaluateAutoStop(newWriter)
    }

    /// Writer queue only.
    private func writeBuffer(_ buffer: AVAudioPCMBuffer, frames: Int64) {
        defer {
            stateLock.lock()
            pendingFrames = max(0, pendingFrames - frames)
            stateLock.unlock()
        }

        guard let writer, !writeFailed else { return }

        do {
            try writer.write(buffer)
        } catch {
            // Once per recording: the capture callback stops feeding this queue below,
            // but buffers already in flight would otherwise each log and each report.
            writeFailed = true
            let message = error.localizedDescription
            Log.error("Write failed: \(message)")
            reportWriteFailure("Recording stopped — write failed: \(message)", sessionID: writerSessionID)
            return
        }

        publishProgress(writer)
        evaluateAutoStop(writer)
    }

    /// Publishes elapsed audio for the menu timer. Writer queue only.
    private func publishProgress(_ writer: AudioFileWriter) {
        stateLock.lock()
        writtenFrames = writer.framesWritten
        writtenSampleRate = writer.sampleRate
        stateLock.unlock()
    }

    /// Auto-stop is still judged on what has actually been written, and still fires on
    /// the main queue. Writer queue only.
    private func evaluateAutoStop(_ writer: AudioFileWriter) {
        guard activeAutoStopSeconds > 0, !autoStopFired, writer.duration >= activeAutoStopSeconds else { return }
        autoStopFired = true
        let limit = activeAutoStopSeconds
        let sessionID = writerSessionID
        DispatchQueue.main.async {
            guard self.queue.sync(execute: { self.recordingID == sessionID && self.isWriting }) else { return }
            self.onAutoStop?(limit)
        }
    }

    private func reportWriteFailure(_ message: String, sessionID: UUID) {
        queue.async {
            guard self.recordingID == sessionID, self.isWriting else { return }
            self.isWriting = false
            DispatchQueue.main.async {
                guard self.queue.sync(execute: { self.recordingID == sessionID }) else { return }
                self.onStreamError?(message)
            }
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.error("Capture stream stopped with error: \(error.localizedDescription)")
        let message = error.localizedDescription
        DispatchQueue.main.async {
            // A late callback from a stream we already replaced (a sample-rate change) or
            // deliberately stopped must not clear the reference to the *live* one, which
            // would leave it — and the recording indicator — running for good.
            guard self.stream === stream else {
                Log.info("Ignoring a stop callback from a stream JustRecorder no longer owns.")
                return
            }
            _ = ScreenRecordingPermission.captureError(error)
            self.stream = nil
            self.runningSampleRate = 0
            // Audio from a dead stream must not become the next recording's pre-roll.
            self.queue.async {
                self.preRoll?.clear()
                self.captureFormatCache = nil
            }
            self.onStreamError?("System audio capture stopped: \(message)")
        }
    }
}
