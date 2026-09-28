import Foundation

/// Turns raw window titles such as
/// `(3) Example Artist - Example Track (Live) - YouTube — Google Chrome` into `Example Artist - Example Track (Live)`.
enum TitleCleaner {

    /// Site / player suffixes that carry no information for a snippet name.
    /// Matched case-insensitively, so one spelling per site is enough.
    private static let siteSuffixes = [
        "YouTube Music", "YouTube", "Bilibili", "SoundCloud", "Spotify",
        "Apple Music", "Vimeo", "Twitch", "Bandcamp", "Mixcloud", "Beatport", "Audiomack",
        "NetEase Cloud Music", "\u{7F51}\u{6613}\u{4E91}\u{97F3}\u{4E50}", "QQ\u{97F3}\u{4E50}", "\u{9177}\u{72D7}\u{97F3}\u{4E50}", "\u{9177}\u{6211}\u{97F3}\u{4E50}", "\u{54AA}\u{5495}\u{97F3}\u{4E50}",
        "\u{559C}\u{9A6C}\u{62C9}\u{96C5}", "\u{817E}\u{8BAF}\u{89C6}\u{9891}", "\u{7231}\u{5947}\u{827A}", "\u{4F18}\u{9177}", "\u{6296}\u{97F3}", "\u{5C0F}\u{7EA2}\u{4E66}", "Deezer", "Tidal", "Pandora"
    ]

    /// Browser / app chrome that macOS appends to window titles.
    private static let appSuffixes = [
        "Google Chrome", "Chromium", "Google Chrome Canary", "Safari", "Safari Technology Preview",
        "Microsoft Edge", "Brave Browser", "Brave", "Firefox", "Mozilla Firefox", "Arc",
        "Opera", "Vivaldi", "Orion", "Zen Browser", "Dia"
    ]

    private static let patterns: [(pattern: String, replacement: String)] = [
        // Leading unread/notification badges and play markers.
        (#"^\(\d+\)\s*"#, ""),
        (#"^\[\d+\]\s*"#, ""),
        // `\uFE0F` is the emoji variation selector that trails "⏸️".
        (#"^[▶►▷🔊🎵🎧🎶⏸❚\uFE0F]+\s*"#, ""),
        (#"^(Now Playing|\u6B63\u5728\u64AD\u653E)[:：]\s*"#, ""),
        // Chrome's window-title tail.
        (#"\s+and\s+\d+\s+more\s+pages?$"#, ""),
        // bilibili's decorated titles ("…_localized text_bilibili", "…-localized text").
        (#"[_-]\u54D4\u54E9\u54D4\u54E9[_-]?(bilibili)?$"#, ""),
        (#"\s*[-_]\s*\u9AD8\u6E05\d*P?\u5728\u7EBF\u89C2\u770B.*$"#, ""),
        // Video sites love appending marketing tails.
        (#"\s*[-—|]\s*(\u514D\u8D39\u5728\u7EBF\u89C2\u770B|\u5728\u7EBF\u64AD\u653E|\u9AD8\u6E05\u5B8C\u6574\u7248).*$"#, ""),
        // Collapse whitespace, trim stray separators.
        (#"\s{2,}"#, " "),
        (#"^\s*[-–—|·:：]\s*"#, ""),
        (#"\s*[-–—|·:：]\s*$"#, "")
    ]

    /// Compiled once and reused. `clean` runs every one of these up to three times per
    /// detection, and building an `NSRegularExpression` means an ICU pattern compile:
    /// ~30 of them per recording were being thrown away immediately.
    private static let compiledPatterns: [(regex: NSRegularExpression, replacement: String)] =
        patterns.compactMap { entry in
            guard let regex = try? NSRegularExpression(pattern: entry.pattern) else { return nil }
            return (regex, entry.replacement)
        }

    static func clean(_ raw: String, appName: String? = nil) -> String {
        var title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return "" }

        // Three passes: titles like "Song - YouTube - Google Chrome" need layered stripping.
        for _ in 0..<3 {
            let before = title

            for suffix in appSuffixes { title = stripSuffix(suffix, from: title) }
            for suffix in siteSuffixes { title = stripSuffix(suffix, from: title) }
            if let appName, !appName.isEmpty { title = stripSuffix(appName, from: title) }

            for (regex, replacement) in compiledPatterns {
                let range = NSRange(title.startIndex..<title.endIndex, in: title)
                title = regex.stringByReplacingMatches(
                    in: title, options: [], range: range, withTemplate: replacement
                )
            }

            title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if title == before { break }
        }

        return title
    }

    /// The separators a site/app suffix can hang off.
    private static let suffixSeparators: Set<Character> = ["-", "–", "—", "|", "·"]

    /// Removes ` - Suffix`, ` — Suffix`, ` | Suffix`, ` · Suffix` (case-insensitive).
    private static func stripSuffix(_ suffix: String, from title: String) -> String {
        guard !suffix.isEmpty, !title.isEmpty else { return title }

        // `\s*$`
        var end = title.endIndex
        while end > title.startIndex, title[title.index(before: end)].isWhitespace {
            end = title.index(before: end)
        }
        // the suffix itself, anchored at that end
        guard let match = title.range(
            of: suffix,
            options: [.caseInsensitive, .backwards, .anchored],
            range: title.startIndex..<end
        ) else { return title }

        // `\s*` between the separator and the suffix
        var cut = match.lowerBound
        while cut > title.startIndex, title[title.index(before: cut)].isWhitespace {
            cut = title.index(before: cut)
        }
        // the separator …
        guard cut > title.startIndex,
              suffixSeparators.contains(title[title.index(before: cut)])
        else { return title }
        cut = title.index(before: cut)
        // … and the `\s*` in front of it
        while cut > title.startIndex, title[title.index(before: cut)].isWhitespace {
            cut = title.index(before: cut)
        }
        return String(title[title.startIndex..<cut])
    }
}

/// Makes a string safe to use as a macOS file name.
enum FilenameSanitizer {

    private static let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|")
        .union(.controlCharacters)

    /// APFS/HFS+ reject a name longer than 255 UTF-8 bytes, which a CJK title reaches
    /// at ~85 characters. Leaving room for " 999" plus an extension.
    private static let maxUTF8Bytes = 200

    // Compiled on first use and reused. `sanitize` is called five to eight times per
    // recording (once per name token, once for the rendered name, once for an AI reply),
    // and `replacingOccurrences(options: .regularExpression)` compiles a fresh ICU pattern
    // on every call — ~30 throwaway compiles and their pattern objects per clip.
    private static let whitespaceRuns = try? NSRegularExpression(pattern: #"\s{2,}"#)
    private static let hyphenRuns = try? NSRegularExpression(pattern: #"-{2,}"#)
    private static let hyphenAfterSpace = try? NSRegularExpression(pattern: #" +- *"#)
    private static let hyphenBeforeSpace = try? NSRegularExpression(pattern: #" *- +"#)

    private static func replacing(
        _ regex: NSRegularExpression?,
        in input: String,
        with template: String
    ) -> String {
        guard let regex, !input.isEmpty else { return input }
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        return regex.stringByReplacingMatches(in: input, options: [], range: range, withTemplate: template)
    }

    /// Runs of two or more whitespace characters collapsed to one space. Shared with
    /// `NameTemplate.render`, which needs exactly the same pass.
    static func collapsingWhitespace(_ input: String) -> String {
        replacing(whitespaceRuns, in: input, with: " ")
    }

    static func sanitize(_ input: String, maxLength: Int = 120) -> String {
        // Most titles contain no illegal character at all, and then there is nothing to
        // split and rejoin: `components(separatedBy:)` allocated an array of pieces plus
        // the joined copy for every one of them.
        var result = input.rangeOfCharacter(from: illegal) == nil
            ? input
            : input.components(separatedBy: illegal).joined(separator: "-")

        // Collapse whitespace and repeated separators produced by the substitution above.
        result = collapsingWhitespace(result)
        result = Self.replacing(hyphenRuns, in: result, with: "-")
        // Substituting an illegal character leaves lopsided spacing behind:
        // "Interstellar: Main Theme" became "Interstellar- Main Theme". Even out a hyphen
        // that has whitespace on at least one side; "AC-DC" (no space) is left alone.
        result = Self.replacing(hyphenAfterSpace, in: result, with: " - ")
        result = Self.replacing(hyphenBeforeSpace, in: result, with: " - ")
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)

        // Never produce a hidden file, "." or ".." — all rejected or invisible.
        while result.hasPrefix(".") { result.removeFirst() }
        result = result.trimmingCharacters(in: .whitespaces)

        if result.count > maxLength {
            result = String(result.prefix(max(0, maxLength)))
        }
        while result.utf8.count > maxUTF8Bytes, !result.isEmpty {
            result.removeLast()
        }

        // Truncation can land on a period or a space, which macOS also dislikes.
        while result.hasSuffix(".") || result.hasSuffix(" ") { result.removeLast() }
        return result
    }
}
