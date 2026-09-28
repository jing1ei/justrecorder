import Foundation

/// Severity comes from the operation, never from words in a saved track title.
struct RecordingStatus {
    let message: String
    let needsAttention: Bool

    var menuCaption: String {
        let line = message.components(separatedBy: .newlines).joined(separator: " ")
        guard line.count > 72 else { return line }
        return String(line.prefix(48)) + "…" + String(line.suffix(20))
    }
}
