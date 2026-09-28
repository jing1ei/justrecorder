import Foundation

enum DurationFormatter {

    /// `1m3s`, `45s`, `1h2m3s` — always rounded to whole seconds.
    static func compact(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60

        if hours > 0 { return "\(hours)h\(minutes)m\(secs)s" }
        if minutes > 0 { return "\(minutes)m\(secs)s" }
        return "\(secs)s"
    }

    /// `0:12` / `1:02:03` — for the menu bar timer.
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60

        if hours > 0 { return "\(hours):\(padded(minutes)):\(padded(secs))" }
        return "\(minutes):\(padded(secs))"
    }

    /// Two digits, for values that are always 0…59 here.
    private static func padded(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }
}
