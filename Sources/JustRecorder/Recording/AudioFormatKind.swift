import Foundation
// Audio-only subframework; see AudioFileWriter.swift.
import AVFAudio

enum AudioFormatKind: String, CaseIterable, Identifiable {
    case aac
    case mp3
    case alac
    case wav24
    case wav16

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .aac:   return "AAC (.m4a) — recommended"
        case .mp3:   return "MP3 (.mp3) — needs lame/ffmpeg"
        case .alac:  return "Apple Lossless (.m4a)"
        case .wav24: return "WAV 24-bit (.wav)"
        case .wav16: return "WAV 16-bit (.wav)"
        }
    }

    var shortName: String {
        switch self {
        case .aac: return "AAC"
        case .mp3: return "MP3"
        case .alac: return "ALAC"
        case .wav24: return "WAV 24"
        case .wav16: return "WAV 16"
        }
    }

    var fileExtension: String {
        switch self {
        case .aac, .alac: return "m4a"
        case .mp3: return "mp3"
        case .wav24, .wav16: return "wav"
        }
    }

    /// MP3 is encoded after the fact, so capture goes to a 16-bit WAV intermediate.
    var captureFormat: AudioFormatKind {
        self == .mp3 ? .wav16 : self
    }

    func approximateMBPerMinute(sampleRate: Int, bitrateKbps: Int) -> Double {
        switch self {
        case .aac, .mp3:
            return Double(bitrateKbps) * 60 / 8 / 1024
        case .alac:
            return Double(sampleRate) * 3 * 2 * 60 / 1_048_576 * 0.6
        case .wav24:
            return Double(sampleRate) * 3 * 2 * 60 / 1_048_576
        case .wav16:
            return Double(sampleRate) * 2 * 2 * 60 / 1_048_576
        }
    }

    /// `AVAudioFile` output settings for this format.
    func writerSettings(sampleRate: Double, channels: AVAudioChannelCount, aacBitrateKbps: Int) -> [String: Any] {
        let channelCount = Int(channels)
        switch self {
        case .aac:
            return [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channelCount,
                AVEncoderBitRateKey: aacBitrateKbps * 1000,
                AVEncoderAudioQualityKey: AVAudioQuality.max.rawValue
            ]
        case .alac:
            return [
                AVFormatIDKey: kAudioFormatAppleLossless,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channelCount,
                AVEncoderBitDepthHintKey: 24
            ]
        case .wav24:
            return [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channelCount,
                AVLinearPCMBitDepthKey: 24,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
        case .wav16, .mp3: // `.mp3` is unreachable — see the note above.
            return [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channelCount,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
        }
    }

    static let aacBitrateChoices = [128, 160, 192, 256, 320]
}
