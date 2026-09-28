import Foundation
// Audio-only framework.
import AVFAudio
import CoreMedia

// MARK: - CMSampleBuffer / AVAudioPCMBuffer bridging

extension CMSampleBuffer {

    /// The `AVAudioFormat` describing this sample buffer's audio, or `nil` for anything
    /// JustRecorder cannot handle.
    /// - Parameter cachedFormat: storage owned by the calling queue, reused across calls.
    ///   Building an `AVAudioFormat` (and with it a channel layout) allocates, and the
    ///   capture callback runs for every buffer, so the format is rebuilt only when the
    ///   stream's rate or channel count actually changes.
    func pcmFormat(cachedFormat: inout AVAudioFormat?) -> AVAudioFormat? {
        guard let streamDescription = formatDescription?.audioStreamBasicDescription else { return nil }
        let isFloat = streamDescription.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let isDeinterleaved = streamDescription.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        guard streamDescription.mFormatID == kAudioFormatLinearPCM,
              isFloat,
              streamDescription.mBitsPerChannel == 32,
              streamDescription.mBytesPerFrame == 4 * (isDeinterleaved ? 1 : streamDescription.mChannelsPerFrame),
              streamDescription.mSampleRate.isFinite,
              (8_000...192_000).contains(streamDescription.mSampleRate),
              (1...8).contains(streamDescription.mChannelsPerFrame)
        else { return nil }

        if let cached = cachedFormat,
           cached.sampleRate == streamDescription.mSampleRate,
           cached.channelCount == streamDescription.mChannelsPerFrame,
           cached.isInterleaved == !isDeinterleaved {
            return cached
        }
        guard let built = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: streamDescription.mSampleRate,
            channels: streamDescription.mChannelsPerFrame,
            interleaved: !isDeinterleaved
        ) else { return nil }
        cachedFormat = built
        return built
    }

    /// An **owned** `AVAudioPCMBuffer` holding a copy of this sample buffer's audio, for
    /// the writer queue to consume after the capture callback has returned.
    /// The copy is taken *inside* `withAudioBufferList`: the buffer list it vends (and the
    /// block buffer backing it) is only valid until that closure returns, so a no-copy
    /// wrapper must never escape it. Copying per channel straight into the destination
    /// also avoids allocating an intermediate no-copy `AVAudioPCMBuffer` per capture
    /// buffer just to copy out of it again.
    func copiedPCMBuffer(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        try? withAudioBufferList { list, _ -> AVAudioPCMBuffer? in
            let channels = Int(format.channelCount)
            let planes = format.isInterleaved ? 1 : channels
            let bytesPerFrame = MemoryLayout<Float>.size * (format.isInterleaved ? channels : 1)
            let frames = numSamples
            guard channels > 0, list.count >= planes, frames > 0,
                  frames <= 8_000_000,
                  (0..<planes).allSatisfy({ list[$0].mData != nil && Int(list[$0].mDataByteSize) >= frames * bytesPerFrame }),
                  let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
                  let destination = copy.floatChannelData
            else { return nil }
            copy.frameLength = AVAudioFrameCount(frames)
            for plane in 0..<planes {
                memcpy(destination[plane], list[plane].mData!, frames * bytesPerFrame)
            }
            return copy
        }
    }
}

extension AVAudioPCMBuffer {

    /// Whether any sample exceeds `threshold`, bailing out at the first one that does.
    func containsAudio(above threshold: Float) -> Bool {
        guard let data = floatChannelData, frameLength > 0 else { return false }
        let channels = max(1, Int(format.channelCount))
        // Interleaved: one block of `frameLength × channels` samples in `data[0]`.
        // Deinterleaved: `channels` planes of `frameLength` samples each.
        let planes = format.isInterleaved ? 1 : channels
        let samplesPerPlane = format.isInterleaved ? Int(frameLength) * channels : Int(frameLength)
        for plane in 0..<planes {
            let samples = data[plane]
            for index in 0..<samplesPerPlane where abs(samples[index]) > threshold {
                return true
            }
        }
        return false
    }
}

// MARK: - Writer

/// Thin wrapper around `AVAudioFile` that also tracks duration and whether anything was
/// actually audible.
/// **Not thread-safe, and deliberately so:** every member is touched only from
/// `SystemAudioRecorder`'s writer queue, never from the capture callback — opening the
/// file, `write`, the `AVAudioConverter` pass and `close` all block on disk or on the
/// encoder.
final class AudioFileWriter {

    /// Roughly -66 dBFS. Below this over a whole recording, nothing was playing.
    static let silenceFloor: Float = 0.0005

    let url: URL
    let sampleRate: Double

    private var file: AVAudioFile?
    private(set) var framesWritten: AVAudioFramePosition = 0
    /// Set by the first buffer that rises above `silenceFloor`; never scanned again after.
    private(set) var didHearAudio = false

    /// Reused converter for buffers whose format differs from the file's processing
    /// format, plus the input format it was built for and its scratch output buffer —
    /// none of which may be rebuilt per buffer.
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private var conversionBuffer: AVAudioPCMBuffer?
    private var didLogMismatch = false
    private var didLogDrop = false

    init(url: URL, settings: [String: Any], sampleRate: Double) throws {
        self.url = url
        self.sampleRate = sampleRate
        self.file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
    }

    var duration: TimeInterval {
        sampleRate > 0 ? Double(framesWritten) / sampleRate : 0
    }

    /// Appends `buffer` to the file.
    func write(_ buffer: AVAudioPCMBuffer) throws {
        guard let file, buffer.frameLength > 0 else { return }
        let target = file.processingFormat

        let outgoing: AVAudioPCMBuffer
        if buffer.format.isEqual(target) {
            outgoing = buffer
        } else {
            if !didLogMismatch {
                didLogMismatch = true
                Log.warn("""
                Capture format \(Int(buffer.format.sampleRate)) Hz/\(buffer.format.channelCount) ch \
                differs from the file's \(Int(target.sampleRate)) Hz/\(target.channelCount) ch; converting.
                """)
            }
            guard let converted = convert(buffer, to: target) else { return }
            outgoing = converted
        }

        try file.write(from: outgoing)
        framesWritten += AVAudioFramePosition(outgoing.frameLength)
        if !didHearAudio, outgoing.containsAudio(above: Self.silenceFloor) {
            didHearAudio = true
        }
    }

    /// Converts into the file's format, or returns `nil` (buffer dropped, logged once).
    private func convert(_ buffer: AVAudioPCMBuffer, to target: AVAudioFormat) -> AVAudioPCMBuffer? {
        // Build the converter lazily, and rebuild it only if the input format changes again.
        if converter == nil || converterInputFormat?.isEqual(buffer.format) != true {
            guard let newConverter = AVAudioConverter(from: buffer.format, to: target) else {
                dropOnce("no converter from the capture format to the file format")
                return nil
            }
            converter = newConverter
            converterInputFormat = buffer.format
            conversionBuffer = nil
        }
        guard let converter else { return nil }

        // A sample-rate change alters the frame count, so the output has to be sized for
        // the ratio; the extra frames cover the resampler's own latency. The upper bound
        // keeps a nonsensical format (0 Hz, a 1 Hz "sample rate") from trapping the
        // `Double` → `AVAudioFrameCount` conversion or asking for a huge allocation.
        let ratio = target.sampleRate / buffer.format.sampleRate
        guard ratio > 0, ratio.isFinite else {
            dropOnce("implausible sample-rate ratio")
            return nil
        }
        let scaledFrames = (Double(buffer.frameLength) * ratio).rounded(.up) + 1024
        guard scaledFrames > 0, scaledFrames <= 8_000_000 else {
            dropOnce("implausible converted frame count")
            return nil
        }

        // Reused across buffers: capture buffers are all the same size, so the converter's
        // scratch output is allocated once instead of once per buffer. `file.write` consumes
        // it synchronously, so nothing else can be holding it.
        let needed = AVAudioFrameCount(scaledFrames)
        let output: AVAudioPCMBuffer
        if let scratch = conversionBuffer, scratch.frameCapacity >= needed {
            output = scratch
        } else {
            guard let fresh = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: needed) else {
                dropOnce("could not allocate a conversion buffer")
                return nil
            }
            output = fresh
            // A one-off oversized conversion (a whole pre-roll run at the wrong rate) is
            // not worth keeping: it would leave megabytes retained for the recording.
            if needed <= 65_536 { conversionBuffer = fresh }
        }

        var didSupplyInput = false
        var conversionError: NSError?
        // The converter fills `output` up to its capacity and sets `frameLength` itself;
        // clearing it first keeps a reused buffer's previous length from being read as
        // audio if the conversion produces nothing.
        output.frameLength = 0
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            // The whole (single) input buffer is handed over once; after that the
            // converter is told the input ran dry so it flushes what it can.
            if didSupplyInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            didSupplyInput = true
            inputStatus.pointee = .haveData
            return buffer
        }

        switch status {
        case .haveData, .inputRanDry, .endOfStream:
            // `.inputRanDry` / `.endOfStream` still leave whatever was produced in `output`.
            return output.frameLength > 0 ? output : nil
        case .error:
            dropOnce(conversionError?.localizedDescription ?? "conversion failed")
            return nil
        @unknown default:
            dropOnce("unknown converter status")
            return nil
        }
    }

    /// One line per writer, however many buffers are dropped: a dropped buffer is a
    /// glitch, not a reason to flood the log (or crash).
    private func dropOnce(_ reason: String) {
        guard !didLogDrop else { return }
        didLogDrop = true
        Log.warn("Dropping capture buffers the file cannot accept — \(reason).")
    }

    /// Flushes and closes the file (`AVAudioFile` finalises on deallocation), and drops
    /// the encoder-side scratch state with it — nothing is kept "warm" for a next
    /// recording that may never come.
    func close() {
        file = nil
        converter = nil
        converterInputFormat = nil
        conversionBuffer = nil
    }
}
