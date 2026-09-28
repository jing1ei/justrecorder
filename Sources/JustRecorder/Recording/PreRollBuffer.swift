import Foundation
// Audio-only subframework; see AudioFileWriter.swift.
import AVFAudio
import CoreMedia

/// Rolling planar-float audio owned by the capture queue. Draining returns copies
/// for the writer queue, then releases the ring storage.
final class PreRollBuffer {

    /// `channelCount × capacityFrames` floats, or `nil` when the ring holds nothing.
    private var storage: UnsafeMutablePointer<Float>?
    /// Format the ring currently holds. A different one resets it (see `append`).
    private var format: AVAudioFormat?
    private var capacityFrames = 0
    private var channelCount = 0
    /// Next frame slot to write, and how many of `capacityFrames` are valid.
    private var writeIndex = 0
    private var filledFrames = 0
    private var seconds: Int

    init(seconds: Int) {
        self.seconds = Self.clamped(seconds)
    }

    deinit { release() }

    func setSeconds(_ newValue: Int) {
        let value = Self.clamped(newValue)
        guard value != seconds else { return }
        seconds = value
        // The ring is sized from `seconds`, so a new length means a new allocation. What
        // was buffered is dropped rather than copied across: this only happens when the
        // user moves the pre-roll slider, never during a capture.
        release()
    }

    /// Copies `sampleBuffer`'s audio into the ring, overwriting the oldest frames.
    func append(_ sampleBuffer: CMSampleBuffer, format incoming: AVAudioFormat) {
        guard prepare(for: incoming), let storage else { return }
        let channels = channelCount
        let capacity = capacityFrames
        _ = try? sampleBuffer.withAudioBufferList { list, _ -> Void in
            let planes = incoming.isInterleaved ? 1 : channels
            let bytesPerFrame = MemoryLayout<Float>.size * (incoming.isInterleaved ? channels : 1)
            var frames = sampleBuffer.numSamples
            guard list.count >= planes, frames > 0, frames <= 8_000_000,
                  (0..<planes).allSatisfy({ list[$0].mData != nil && Int(list[$0].mDataByteSize) >= frames * bytesPerFrame })
            else { return }

            // A single buffer longer than the whole ring: keep only its tail.
            var sourceOffset = 0
            if frames > capacity {
                sourceOffset = frames - capacity
                frames = capacity
            }

            let head = min(frames, capacity - writeIndex)
            let wrapped = frames - head
            for channel in 0..<channels {
                let base = storage + channel * capacity
                if incoming.isInterleaved {
                    let source = list[0].mData!.assumingMemoryBound(to: Float.self)
                    for frame in 0..<frames {
                        base[(writeIndex + frame) % capacity] = source[(sourceOffset + frame) * channels + channel]
                    }
                } else {
                    let source = list[channel].mData!.assumingMemoryBound(to: Float.self) + sourceOffset
                    memcpy(base + writeIndex, source, head * MemoryLayout<Float>.size)
                    if wrapped > 0 { memcpy(base, source + head, wrapped * MemoryLayout<Float>.size) }
                }
            }
            writeIndex = (writeIndex + frames) % capacity
            filledFrames = min(capacity, filledFrames + frames)
        }
    }

    /// Everything buffered, oldest first, as at most two buffers — one per contiguous run
    /// in the ring — and then frees the ring.
    func drain(matching target: AVAudioFormat) -> [AVAudioPCMBuffer] {
        defer { release() }
        guard let storage, let format, format.sampleRate == target.sampleRate,
              format.channelCount == target.channelCount, filledFrames > 0 else { return [] }

        let start = (writeIndex - filledFrames + capacityFrames) % capacityFrames
        let head = min(filledFrames, capacityFrames - start)
        var result: [AVAudioPCMBuffer] = []
        result.reserveCapacity(2)
        if let first = copy(from: storage, at: start, frames: head, format: format) {
            result.append(first)
        }
        let tail = filledFrames - head
        if tail > 0, let second = copy(from: storage, at: 0, frames: tail, format: format) {
            result.append(second)
        }
        return result
    }

    func clear() { release() }

    // MARK: - Private

    /// Ensures the ring exists and matches `incoming`; resets it when it does not.
    private func prepare(for incoming: AVAudioFormat) -> Bool {
        if storage != nil, let format, format.sampleRate == incoming.sampleRate,
           format.channelCount == incoming.channelCount { return true }
        release()
        guard incoming.commonFormat == .pcmFormatFloat32,
              incoming.sampleRate.isFinite,
              (8_000...192_000).contains(incoming.sampleRate),
              (1...8).contains(incoming.channelCount),
              let planar = AVAudioFormat(standardFormatWithSampleRate: incoming.sampleRate, channels: incoming.channelCount)
        else { return false }
        let channels = Int(incoming.channelCount)
        let frames = Int((Double(seconds) * incoming.sampleRate).rounded())
        guard frames > 0 else { return false }
        storage = UnsafeMutablePointer<Float>.allocate(capacity: channels * frames)
        format = planar
        capacityFrames = frames
        channelCount = channels
        return true
    }

    private func copy(
        from storage: UnsafeMutablePointer<Float>,
        at offset: Int,
        frames: Int,
        format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let destination = buffer.floatChannelData
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        let bytes = frames * MemoryLayout<Float>.size
        for channel in 0..<channelCount {
            memcpy(destination[channel], storage + channel * capacityFrames + offset, bytes)
        }
        return buffer
    }

    private func release() {
        storage?.deallocate()
        storage = nil
        format = nil
        capacityFrames = 0
        channelCount = 0
        writeIndex = 0
        filledFrames = 0
    }

    /// A corrupt preference must not turn into a huge allocation; the UI offers 5–30 s.
    private static func clamped(_ seconds: Int) -> Int { min(max(seconds, 1), 60) }
}
