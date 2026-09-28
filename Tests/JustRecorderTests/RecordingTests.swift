import Foundation
import AVFAudio
import CoreMedia

final class RecordingTests: RegressionCase {
    private func audio(frames: Int, rate: Double = 48_000, offset: Int = 0) throws -> AVAudioPCMBuffer {
        let format = try unwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
        let pcm = try unwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        pcm.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<2 {
            for i in 0..<frames { pcm.floatChannelData![channel][i] = Float((i + offset) % 100) / 100 }
        }
        return pcm
    }

    private func sample(_ pcm: AVAudioPCMBuffer) throws -> CMSampleBuffer {
        var description: CMAudioFormatDescription?
        checkEqual(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault,
            asbd: pcm.format.streamDescription, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &description), noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(pcm.format.sampleRate)),
                                        presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var result: CMSampleBuffer?
        checkEqual(CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil,
            dataReady: false, makeDataReadyCallback: nil, refcon: nil,
            formatDescription: description, sampleCount: Int(pcm.frameLength),
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &result), noErr)
        let buffer = try unwrap(result)
        checkEqual(CMSampleBufferSetDataBufferFromAudioBufferList(buffer,
            blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0, bufferList: pcm.audioBufferList), noErr)
        checkEqual(CMSampleBufferSetDataReady(buffer), noErr)
        return buffer
    }

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }

    func testSlowWriterReturnsImmediatelyAndFinalizesOnlyAfterClose() throws {
        let queue = DispatchQueue(label: "test.slow-writer")
        let gate = DispatchSemaphore(value: 0)
        let entered = DispatchSemaphore(value: 0)
        queue.async { entered.signal(); gate.wait() }
        entered.wait()
        let recorder = SystemAudioRecorder(writerQueue: queue)
        let url = try folder().appendingPathComponent("slow.m4a")
        recorder.startWriting(to: url, format: .aac, bitrateKbps: 256, autoStopAfter: 0)
        recorder.consumeAudio(try sample(audio(frames: 24_000)))
        let finished = expectation(description: "closed audio")
        var completed = false
        let before = Date()
        recorder.stopWriting { result in
            completed = true
            checkTrue(Thread.isMainThread)
            checkEqual(result?.duration ?? 0, 0.5, accuracy: 0.001)
            checkFalse(result?.isEffectivelySilent ?? true)
            checkGreaterThan((try? AVAudioFile(forReading: url).length) ?? 0, 0)
            finished.fulfill()
        }
        checkLessThan(Date().timeIntervalSince(before), 0.25)
        checkFalse(completed)
        gate.signal()
        wait(for: [finished], timeout: 5)
    }

    func testPreRollKeepsNewestFramesInOrderAndDrainsOnce() throws {
        let ring = PreRollBuffer(seconds: 1)
        let first = try audio(frames: 30_000)
        ring.append(try sample(first), format: first.format)
        let second = try audio(frames: 30_000, offset: 30_000)
        ring.append(try sample(second), format: second.format)
        let drained = ring.drain(matching: first.format)
        checkEqual(drained.reduce(0) { $0 + Int($1.frameLength) }, 48_000)
        var frame = 12_000
        for buffer in drained {
            for i in 0..<Int(buffer.frameLength) {
                checkEqual(buffer.floatChannelData![0][i], Float(frame % 100) / 100)
                frame += 1
            }
        }
        checkTrue(ring.drain(matching: first.format).isEmpty)
    }

    func testAllNativeFormatsProduceReadableAudio() throws {
        let directory = try folder()
        for format in [AudioFormatKind.aac, .alac, .wav16, .wav24] {
            let url = directory.appendingPathComponent(format.rawValue).appendingPathExtension(format.fileExtension)
            let writer = try AudioFileWriter(url: url,
                settings: format.writerSettings(sampleRate: 48_000, channels: 2, aacBitrateKbps: 256), sampleRate: 48_000)
            try writer.write(audio(frames: 48_000))
            writer.close()
            let file = try AVAudioFile(forReading: url)
            checkEqual(Double(file.length) / file.fileFormat.sampleRate, 1, accuracy: 0.05)
        }
    }

    func testInterleavedStereoSurvivesCaptureAndPreRoll() throws {
        let format = try unwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true))
        let pcm = try unwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
        pcm.frameLength = 48_000
        for frame in 0..<48_000 {
            pcm.floatChannelData![0][frame * 2] = 0.25
            pcm.floatChannelData![0][frame * 2 + 1] = -0.5
        }
        let buffer = try sample(pcm)
        var cache: AVAudioFormat?
        let detected = try unwrap(buffer.pcmFormat(cachedFormat: &cache))
        let copy = try unwrap(buffer.copiedPCMBuffer(format: detected))
        checkEqual(copy.frameLength, 48_000)
        checkEqual(copy.floatChannelData![0][0], 0.25)
        checkEqual(copy.floatChannelData![0][1], -0.5)
        let ring = PreRollBuffer(seconds: 1)
        ring.append(buffer, format: detected)
        let drained = ring.drain(matching: detected)
        checkEqual(drained.reduce(0) { $0 + Int($1.frameLength) }, 48_000)
        let planar = try unwrap(drained.first)
        checkEqual(planar.floatChannelData![0][0], 0.25)
        checkEqual(planar.floatChannelData![1][0], -0.5)
        let url = try folder().appendingPathComponent("interleaved.wav")
        let writer = try AudioFileWriter(url: url, settings: AudioFormatKind.wav24.writerSettings(sampleRate: 48_000, channels: 2, aacBitrateKbps: 256), sampleRate: 48_000)
        try writer.write(copy)
        writer.close()
        let file = try AVAudioFile(forReading: url)
        let output = try unwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 48_000))
        try file.read(into: output)
        checkEqual(Double(output.floatChannelData![0][0]), 0.25, accuracy: 0.00001)
        checkEqual(Double(output.floatChannelData![1][0]), -0.5, accuracy: 0.00001)
    }

    func testOldAutoStopCannotStopNextRecording() throws {
        let writerQueue = DispatchQueue(label: "test.old-auto-stop")
        let recorder = SystemAudioRecorder(writerQueue: writerQueue)
        var autoStops = 0
        recorder.onAutoStop = { _ in autoStops += 1 }
        let directory = try folder()
        recorder.startWriting(to: directory.appendingPathComponent("first.wav"), format: .wav16, bitrateKbps: 256, autoStopAfter: 0.1)
        recorder.consumeAudio(try sample(audio(frames: 24_000)))
        writerQueue.sync {}
        let firstClosed = expectation(description: "first closed")
        recorder.stopWriting { _ in firstClosed.fulfill() }
        writerQueue.sync {}
        recorder.startWriting(to: directory.appendingPathComponent("second.wav"), format: .wav16, bitrateKbps: 256, autoStopAfter: 0)
        wait(for: [firstClosed], timeout: 2)
        checkEqual(autoStops, 0)
        let secondClosed = expectation(description: "second closed")
        recorder.stopWriting { _ in secondClosed.fulfill() }
        wait(for: [secondClosed], timeout: 2)
    }

    func testFailedEncoderPreservesSourceAndRemovesPartialOutput() throws {
        let directory = try folder()
        let wav = directory.appendingPathComponent("source.wav")
        try Data("preserve source".utf8).write(to: wav)
        let script = directory.appendingPathComponent("fake encoder")
        try Data("#!/bin/sh\nfor last; do :; done\nprintf broken > \"$last\"\nexit 0\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        checkNil(MP3Transcoder.encode(wavURL: wav, bitrateKbps: 320, encoder: .lame(script.path)))
        checkEqual(try String(contentsOf: wav, encoding: .utf8), "preserve source")
        checkFalse(FileManager.default.fileExists(atPath: wav.deletingPathExtension().appendingPathExtension("mp3").path))
    }

    func testMetadataProcessTimeoutAndOutput() {
        checkEqual(MetadataProcess.run(executable: "/usr/bin/printf", arguments: ["Example Artist\tExample Track"], timeout: 1), "Example Artist\tExample Track")
        let start = Date()
        checkNil(MetadataProcess.run(executable: "/bin/sleep", arguments: ["10"], timeout: 0.1))
        checkLessThan(Date().timeIntervalSince(start), 1.5)
    }

    func testStuckSubprocessHasBoundedLifetime() {
        let start = Date()
        checkNil(ProcessRunner.run(executable: "/bin/sleep", arguments: ["10"], timeout: 0.1))
        checkLessThan(Date().timeIntervalSince(start), 3)
    }
}
