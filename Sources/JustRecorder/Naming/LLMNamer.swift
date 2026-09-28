import Foundation

/// Optional LLM pass that turns a messy window title into a clean file name.
enum LLMNamer {

    struct Config {
        var baseURL: String
        var apiKey: String
        var model: String
        var systemPrompt: String
        var timeout: Double

        static func current() -> Config {
            let settings = Settings.shared
            return Config(
                baseURL: settings.aiBaseURL,
                // Trimmed here as well as on the way into the Keychain: a key stored by an
                // older build (or by the UserDefaults fallback) can still carry the newline
                // that came with the paste, and `URLRequest.setValue` silently drops a
                // header value containing one — every request would then be unauthorised.
                apiKey: (Keychain.readWithFallback() ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                model: settings.aiModel,
                systemPrompt: settings.aiSystemPrompt,
                timeout: settings.aiTimeout
            )
        }

        var isUsable: Bool {
            !baseURL.trimmingCharacters(in: .whitespaces).isEmpty
                && !model.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    enum LLMError: LocalizedError {
        case notConfigured
        case badURL(String)
        case http(Int, String)
        case emptyReply
        case transport(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "AI naming is not configured yet — add a base URL and a model name."
            case .badURL(let value):
                return "“\(value)” is not a valid http(s) base URL."
            case .http(let status, let body):
                let snippet = body.count > 300 ? String(body.prefix(300)) + "…" : body
                return "The API returned HTTP \(status): \(snippet)"
            case .emptyReply:
                return "The model replied with an empty name."
            case .transport(let message):
                return message
            }
        }
    }

    // MARK: - Endpoint

    static func endpoint(from baseURL: String) -> URL? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil
        else { return nil }
        components.fragment = nil
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        if !path.hasSuffix("/chat/completions") {
            path += path.isEmpty ? "/v1/chat/completions" : "/chat/completions"
        }
        components.path = path
        return components.url
    }

    // MARK: - Naming

    /// Returns a cleaned title, or throws. Callers treat every error as "use the heuristic".
    static func suggestTitle(
        source: SourceInfo,
        durationText: String,
        config: Config,
        maxLength: Int
    ) async throws -> String {
        guard config.isUsable else { throw LLMError.notConfigured }
        guard let url = endpoint(from: config.baseURL) else { throw LLMError.badURL(config.baseURL) }

        let userMessage = buildUserMessage(source: source, durationText: durationText)
        let raw = try await complete(
            url: url,
            config: config,
            systemPrompt: config.systemPrompt,
            userMessage: userMessage
        )

        let cleaned = postProcess(raw, maxLength: maxLength)
        // `{title}` is only one slot in the template. The default template is
        // "[{artist} - ]{title} {duration}", so a reply of "Example Artist - Example Track 1m3s" would land
        // on disk as "Example Artist - Example Artist - Example Track 1m3s 1m3s". Neither duplicate is left to the
        // prompt to prevent: any model, and any user-edited prompt, can reintroduce them.
        let deduped = removingTrailingDuration(
            durationText,
            from: removingArtistPrefix(source.artist, from: cleaned)
        )
        guard !deduped.isEmpty else { throw LLMError.emptyReply }
        return deduped
    }

    /// Used by the sample-title test in Settings ▸ AI Naming.
    static func test(config: Config, maxLength: Int) async -> Result<String, Error> {
        var sample = SourceInfo()
        sample.appName = "Google Chrome"
        sample.rawWindowTitle = "(3) Example Artist - Example Track (Live) Official Video - YouTube — Google Chrome"
        sample.cleanedTitle = "Example Artist - Example Track (Live) Video"
        sample.method = "test"

        do {
            let title = try await suggestTitle(
                source: sample,
                durationText: "1m3s",
                config: config,
                maxLength: maxLength
            )
            return .success(title)
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Prompt

    private static func buildUserMessage(source: SourceInfo, durationText: String) -> String {
        var lines: [String] = []
        if !source.rawWindowTitle.isEmpty { lines.append("Window title: \(source.rawWindowTitle)") }
        if !source.cleanedTitle.isEmpty { lines.append("Pre-cleaned guess: \(source.cleanedTitle)") }
        if let track = source.track, !track.isEmpty { lines.append("Track: \(track)") }
        if let artist = source.artist, !artist.isEmpty { lines.append("Artist: \(artist)") }
        if !source.appName.isEmpty { lines.append("App: \(source.appName)") }
        lines.append("Length: \(durationText)")

        if lines.count == 1 {
            lines.insert("Window title: (unavailable)", at: 0)
        }
        lines.append("")
        lines.append("Reply with the file name text only.")
        return lines.joined(separator: "\n")
    }

    // MARK: - HTTP

    private static func complete(
        url: URL,
        config: Config,
        systemPrompt: String,
        userMessage: String
    ) async throws -> String {
        // Built for this one call and thrown away again. `URLSession.shared` would live
        // for the process lifetime with a memory *and* on-disk `URLCache`, a cookie jar
        // and a credential store behind it; none of that has any use here — one POST, one
        // short JSON reply, an `Authorization` header JustRecorder supplies itself every time.
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.urlCache = nil
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        sessionConfiguration.httpCookieStorage = nil
        sessionConfiguration.httpShouldSetCookies = false
        sessionConfiguration.httpCookieAcceptPolicy = .never
        sessionConfiguration.urlCredentialStorage = nil
        // Both attempts below go to the same host, one after the other.
        sessionConfiguration.httpMaximumConnectionsPerHost = 1
        // Unchanged timeout semantics: fail inside the user's budget rather than parking
        // the request until the network comes back.
        sessionConfiguration.waitsForConnectivity = false
        sessionConfiguration.timeoutIntervalForRequest = max(2, config.timeout)
        sessionConfiguration.timeoutIntervalForResource = max(3, config.timeout + 2)
        let session = URLSession(configuration: sessionConfiguration)
        // A session keeps itself alive until it is invalidated.
        defer { session.finishTasksAndInvalidate() }

        var firstFailure: String?

        // Some newer models reject `max_tokens` and want `max_completion_tokens`.
        for tokenKey in ["max_tokens", "max_completion_tokens"] {
            var body: [String: Any] = [
                "model": config.model,
                "messages": [
                    ["role": "system", "content": systemPrompt],
                    ["role": "user", "content": userMessage]
                ],
                "temperature": 0.2,
                "stream": false
            ]
            body[tokenKey] = 96

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if !config.apiKey.isEmpty {
                request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
            }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                throw LLMError.transport(error.localizedDescription)
            }

            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(status) {
                return try parseContent(from: data)
            }

            let bodyText = String(data: data, encoding: .utf8) ?? ""
            if status == 400, tokenKey == "max_tokens", bodyText.contains("max_tokens") {
                firstFailure = bodyText // retry with the other key, but keep the reason
                continue
            }
            throw LLMError.http(status, bodyText)
        }

        // Both token-parameter spellings were rejected.
        throw LLMError.http(400, firstFailure ?? "")
    }

    private static func parseContent(from data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let snippet = String(decoding: data.prefix(200), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw LLMError.transport(
                snippet.isEmpty
                    ? "The API returned an empty response."
                    : "Could not parse the API response as JSON: \(snippet)"
            )
        }

        if let choices = json["choices"] as? [[String: Any]],
           let message = choices.first?["message"] as? [String: Any] {
            if let content = message["content"] as? String {
                return content
            }
            // Some gateways return content as an array of parts.
            if let parts = message["content"] as? [[String: Any]] {
                let text = parts.compactMap { $0["text"] as? String }.joined(separator: " ")
                if !text.isEmpty { return text }
            }
        }

        if let error = json["error"] as? [String: Any],
           let message = error["message"] as? String {
            throw LLMError.transport(message)
        }
        throw LLMError.emptyReply
    }

    // MARK: - Output hygiene

    private static func postProcess(_ raw: String, maxLength: Int) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Keep only the first non-empty line.
        if let firstLine = text.components(separatedBy: .newlines).first(where: {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }) {
            text = firstLine
        }

        // Quotes/markdown the model wrapped the answer in, plus leading or trailing
        // separators and path characters. A reply of "/Song" would otherwise survive as
        // far as `FilenameSanitizer`, which turns the slash into a hyphen and hands back
        // "-Song" (and "Example Artist - -Song 1m3s" with the default template).
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: #"`"'“”‘’ *#/\-–—:|·"#))
        text = text.replacingOccurrences(
            of: #"^(file ?name|filename|name)\s*[:：]\s*"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        // Drop a trailing extension if the model added one anyway.
        text = text.replacingOccurrences(
            of: #"\.(m4a|mp3|wav|aac|aiff?)$"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )

        // A rambling answer means the model ignored the instructions — reject it.
        if text.count > maxLength + 40 { return "" }

        // Reject refusals and meta-chatter, but *not* the many real titles that
        // legitimately start with "I " ("I Will Survive", "I Want It That Way").
        let lowered = text.lowercased()
        if lowered.contains("as an ai") || lowered.contains("language model") { return "" }
        let refusals = ["i'm sorry", "i am sorry", "i cannot", "i can't", "i apologize", "sorry,"]
        if refusals.contains(where: { lowered.hasPrefix($0) }) { return "" }

        let bare = lowered.trimmingCharacters(in: CharacterSet(charactersIn: ".!。！ "))
        if bare == "unknown" || bare == "unknown snippet" { return "" }

        return FilenameSanitizer.sanitize(text, maxLength: maxLength)
    }

    // MARK: - Template-slot de-duplication

    /// Drops a leading "Artist - " when JustRecorder already knows the artist: the template has
    /// its own `{artist}` slot for it. Falls back to the untouched title if stripping
    /// would leave nothing.
    private static func removingArtistPrefix(_ artist: String?, from title: String) -> String {
        guard let artist, !artist.isEmpty, !title.isEmpty else { return title }
        // The reply has already been through `FilenameSanitizer`, so an artist such as
        // "AC/DC" arrives as "AC-DC": both spellings have to be recognised.
        let spellings = [artist, FilenameSanitizer.sanitize(artist, maxLength: 120)]
        for candidate in spellings where !candidate.isEmpty {
            let pattern = "^" + NSRegularExpression.escapedPattern(for: candidate) + #"\s*[-–—:|·]\s*"#
            let stripped = replacing(pattern, in: title)
            if !stripped.isEmpty, stripped != title { return stripped }
        }
        return title
    }

    /// Drops a trailing "1m3s" the model copied out of the `Length:` prompt line — the
    /// template appends `{duration}` itself.
    private static func removingTrailingDuration(_ durationText: String, from title: String) -> String {
        guard !durationText.isEmpty, !title.isEmpty else { return title }
        let pattern = #"[\s\-–—_(\[]*"#
            + NSRegularExpression.escapedPattern(for: durationText)
            + #"[)\]\s.]*$"#
        let stripped = replacing(pattern, in: title)
        return stripped.isEmpty ? title : stripped
    }

    private static func replacing(_ pattern: String, in input: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return input
        }
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        return regex
            .stringByReplacingMatches(in: input, options: [], range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespaces)
    }
}
