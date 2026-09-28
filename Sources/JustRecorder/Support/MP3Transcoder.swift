import Foundation
import AVFAudio

/// macOS ships an MP3 *decoder* but no MP3 *encoder*, so MP3 output is produced by
/// shelling out to `lame` or `ffmpeg` when one of them is installed.
/// AAC (the default) is encoded natively and needs no external tool.
enum MP3Transcoder {

    enum Encoder {
        case lame(String)
        case ffmpeg(String)

        var path: String {
            switch self {
            case .lame(let p): return p
            case .ffmpeg(let p): return p
            }
        }

        var displayName: String {
            switch self {
            case .lame: return "lame"
            case .ffmpeg: return "ffmpeg"
            }
        }
    }

    private static let cacheLock = NSLock()
    private static var cachedEncoder: Encoder?
    private static var didLookUpEncoder = false

    static func locateEncoder() -> Encoder? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if didLookUpEncoder { return cachedEncoder }
        cachedEncoder = findEncoder()
        didLookUpEncoder = true
        return cachedEncoder
    }

    /// Forces the next `locateEncoder()` back to the filesystem — call it wherever the
    /// user may just have installed `lame` / `ffmpeg`.
    static func invalidateEncoderCache() {
        cacheLock.lock()
        cachedEncoder = nil
        didLookUpEncoder = false
        cacheLock.unlock()
    }

    private static func findEncoder() -> Encoder? {
        let candidates: [(String, (String) -> Encoder)] = [
            ("/opt/homebrew/bin/lame", Encoder.lame),
            ("/usr/local/bin/lame", Encoder.lame),
            ("/opt/local/bin/lame", Encoder.lame),
            ("/opt/homebrew/bin/ffmpeg", Encoder.ffmpeg),
            ("/usr/local/bin/ffmpeg", Encoder.ffmpeg),
            ("/opt/local/bin/ffmpeg", Encoder.ffmpeg),
            ("/usr/bin/ffmpeg", Encoder.ffmpeg)
        ]
        let fm = FileManager.default
        for (path, make) in candidates where fm.isExecutableFile(atPath: path) {
            return make(path)
        }
        return nil
    }

    /// Encodes `wavURL` to an MP3 next to it and deletes the source on success.
    /// Returns the MP3 URL, or `nil` when no encoder is available / encoding failed.
    static func transcode(wavURL: URL, bitrateKbps: Int) async -> URL? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: encode(wavURL: wavURL, bitrateKbps: bitrateKbps))
            }
        }
    }

    static func encode(wavURL: URL, bitrateKbps: Int, encoder: Encoder? = locateEncoder(), timeout: TimeInterval = 120) -> URL? {
        guard let encoder else { return nil }

        let outURL = wavURL.deletingPathExtension().appendingPathExtension("mp3")
        try? FileManager.default.removeItem(at: outURL)

        let arguments: [String]
        switch encoder {
        case .lame:
            arguments = ["-b", "\(bitrateKbps)", "--quiet", wavURL.path, outURL.path]
        case .ffmpeg:
            arguments = [
                "-hide_banner", "-loglevel", "error", "-y",
                "-i", wavURL.path,
                "-codec:a", "libmp3lame",
                "-b:a", "\(bitrateKbps)k",
                outURL.path
            ]
        }

        let status = ProcessRunner.run(executable: encoder.path, arguments: arguments, timeout: timeout)
        guard status == 0, isReadableAudio(outURL) else {
            Log.error("\(encoder.displayName) failed or produced no readable audio.")
            try? FileManager.default.removeItem(at: outURL)
            return nil
        }

        try? FileManager.default.removeItem(at: wavURL)
        return outURL
    }
    private static func isReadableAudio(_ url: URL) -> Bool {
        guard let file = try? AVAudioFile(forReading: url) else { return false }
        return file.length > 0 && file.fileFormat.sampleRate > 0
    }
}
