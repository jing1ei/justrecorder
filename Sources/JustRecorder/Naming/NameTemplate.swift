import Foundation

/// Values available to the file-name template.
struct NameContext {
    var title: String = ""
    var rawTitle: String = ""
    var app: String = ""
    var artist: String = ""
    var track: String = ""
    var duration: String = ""
    var seconds: String = ""
    var date: String = ""
    var time: String = ""
    var datetime: String = ""
    var format: String = ""

    func value(for token: String) -> String? {
        switch token {
        case "title": return title
        case "raw_title": return rawTitle
        case "app": return app
        case "artist": return artist
        case "track": return track
        case "duration": return duration
        case "seconds": return seconds
        case "date": return date
        case "time": return time
        case "datetime": return datetime
        case "format": return format
        default: return nil
        }
    }
}

/// Renders the user's file-name template.
enum NameTemplate {

    struct TokenHelpEntry: Identifiable {
        let token: String
        let detail: String
        var id: String { token }
    }

    static let tokenHelp: [TokenHelpEntry] = [
        .init(token: "{title}", detail: "Cleaned-up title (AI-polished when AI naming is on)"),
        .init(token: "{raw_title}", detail: "Untouched window / track title"),
        .init(token: "{artist}", detail: "Artist, when the source exposes one"),
        .init(token: "{track}", detail: "Track name, when the source exposes one"),
        .init(token: "{app}", detail: "App that was playing, e.g. Chrome"),
        .init(token: "{duration}", detail: "Length, e.g. 1m3s"),
        .init(token: "{seconds}", detail: "Length in whole seconds, e.g. 63"),
        .init(token: "{format}", detail: "AAC / MP3 / WAV 24 …"),
        .init(token: "{date}", detail: "2026-08-29"),
        .init(token: "{time}", detail: "14-05-32"),
        .init(token: "{datetime}", detail: "2026-08-29 14-05-32")
    ]

    private enum Segment {
        case plain(String)
        case optional(String)
    }

    /// Whitespace plus every separator an empty token can leave dangling at either end.
    private static let edgeCharacters = CharacterSet(charactersIn: "-–—|·,;:_")
        .union(.whitespacesAndNewlines)

    static func render(_ template: String, context: NameContext, maxLength: Int = 120) -> String {
        let segments = parse(template)

        var output = ""
        for segment in segments {
            switch segment {
            case .plain(let text):
                output += expand(text, context: context).text
            case .optional(let text):
                let result = expand(text, context: context)
                if result.allTokensFilled { output += result.text }
            }
        }

        var name = FilenameSanitizer.collapsingWhitespace(output)
        name = name.trimmingCharacters(in: edgeCharacters)
        name = FilenameSanitizer.sanitize(name, maxLength: maxLength)

        if name.isEmpty {
            // Never lose a recording to a broken template.
            let fallback = [context.title, context.app, "Snippet"].first { !$0.isEmpty } ?? "Snippet"
            name = FilenameSanitizer.sanitize("\(fallback) \(context.duration)", maxLength: maxLength)
        }
        return name
    }

    /// Convenience for the Settings live preview.
    static func preview(
        _ template: String,
        format: String = "AAC",
        titleLimit: Int = 70,
        maxLength: Int = 150
    ) -> String {
        func trim(_ value: String, _ limit: Int) -> String {
            FilenameSanitizer.sanitize(value, maxLength: limit)
        }

        let context = NameContext(
            title: trim("Example Track (Live)", titleLimit),
            rawTitle: trim("(3) Example Artist - Example Track (Live) - YouTube — Google Chrome", titleLimit),
            app: trim("Google Chrome", 40),
            artist: trim("Example Artist", 40),
            track: trim("Example Track (Live)", titleLimit),
            duration: "1m3s",
            seconds: "63",
            date: "2026-08-29",
            time: "14-05-32",
            datetime: "2026-08-29 14-05-32",
            format: format
        )
        return render(template, context: context, maxLength: maxLength)
    }

    // MARK: - Internals

    private static func parse(_ template: String) -> [Segment] {
        var segments: [Segment] = []
        var plain = ""
        var index = template.startIndex

        while index < template.endIndex {
            let character = template[index]
            if character == "[" {
                if !plain.isEmpty {
                    segments.append(.plain(plain))
                    plain = ""
                }
                let innerStart = template.index(after: index)
                if let closing = template[innerStart...].firstIndex(of: "]") {
                    segments.append(.optional(String(template[innerStart..<closing])))
                    index = template.index(after: closing)
                } else {
                    // Unbalanced "[": treat the rest as the optional group rather than
                    // leaking a stray bracket into the file name.
                    segments.append(.optional(String(template[innerStart...])))
                    index = template.endIndex
                }
            } else if character == "]" {
                // Stray "]" — a delimiter, not part of the name.
                index = template.index(after: index)
            } else {
                plain.append(character)
                index = template.index(after: index)
            }
        }

        if !plain.isEmpty { segments.append(.plain(plain)) }
        return segments
    }

    private static let tokenRegex = try? NSRegularExpression(pattern: #"\{([a-zA-Z_]+)\}"#)

    private static func expand(_ text: String, context: NameContext) -> (text: String, allTokensFilled: Bool) {
        guard let tokenRegex else { return (text, true) }

        let nsText = text as NSString
        let matches = tokenRegex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return (text, true) }

        var result = ""
        var cursor = 0
        var allFilled = true

        for match in matches {
            result += nsText.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let token = nsText.substring(with: match.range(at: 1))

            if let value = context.value(for: token) {
                if value.isEmpty { allFilled = false }
                result += value
            } else {
                // Unknown token: keep it visible so typos are obvious.
                result += nsText.substring(with: match.range)
            }
            cursor = match.range.location + match.range.length
        }

        result += nsText.substring(from: cursor)
        return (result, allFilled)
    }
}
