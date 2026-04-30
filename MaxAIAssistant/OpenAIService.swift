import UIKit
import Foundation

enum AIProvider: String, CaseIterable, Identifiable {
    case openAI = "openai"
    case gemini = "gemini"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAI: return "OpenAI"
        case .gemini: return "Gemini"
        }
    }

    var defaultModel: String {
        switch self {
        case .openAI: return "gpt-4o-mini"
        case .gemini: return "gemini-2.5-flash"
        }
    }

    var chatCompletionsURL: URL {
        switch self {
        case .openAI:
            return URL(string: "https://api.openai.com/v1/chat/completions")!
        case .gemini:
            return URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")!
        }
    }

    var keychainKeyName: String {
        switch self {
        case .openAI: return KeychainHelper.openAIKeyName
        case .gemini: return KeychainHelper.geminiKeyName
        }
    }

    var modelDefaultsKey: String {
        switch self {
        case .openAI: return "openai_model"
        case .gemini: return "gemini_model"
        }
    }

    var legacyAPIKeyDefaultsKey: String {
        switch self {
        case .openAI: return "openai_api_key"
        case .gemini: return "gemini_api_key"
        }
    }

    static let selectedDefaultsKey = "ai_provider"

    static var selected: AIProvider {
        let raw = UserDefaults.standard.string(forKey: selectedDefaultsKey)
        return AIProvider(rawValue: raw ?? "") ?? .openAI
    }
}

/// Low-level OpenAI HTTP client.
/// High-level orchestration lives in AgentBrain.
class OpenAIService {
    static let shared = OpenAIService()
    private static var geminiRateLimitedUntil: Date?
    private static let geminiRateLimitLock = NSLock()

    // Internal (not private) so ProxyAIService can subclass from another file.
    init() {}

    private static func setGeminiRateLimitCooldown(seconds: Int) {
        guard seconds > 0 else { return }
        geminiRateLimitLock.lock()
        geminiRateLimitedUntil = Date().addingTimeInterval(TimeInterval(seconds))
        geminiRateLimitLock.unlock()
    }

    private static func currentGeminiCooldownSeconds() -> Int? {
        geminiRateLimitLock.lock()
        defer { geminiRateLimitLock.unlock() }
        guard let until = geminiRateLimitedUntil else { return nil }
        let remaining = Int(ceil(until.timeIntervalSinceNow))
        return remaining > 0 ? remaining : nil
    }

    private static func parseRetryAfterSeconds(from data: Data) -> Int? {
        guard let raw = String(data: data, encoding: .utf8) else { return nil }
        // Prefer structured RetryInfo if present: "retryDelay": "34s"
        if let range = raw.range(of: "\"retryDelay\"\\s*:\\s*\"(\\d+)s\"", options: .regularExpression) {
            let match = String(raw[range])
            if let num = match.components(separatedBy: CharacterSet.decimalDigits.inverted)
                .first(where: { !$0.isEmpty }),
               let seconds = Int(num) {
                return seconds
            }
        }
        // Fallback for text form: "Please retry in 34.46s."
        if let range = raw.range(of: "Please retry in\\s+([0-9]+)", options: .regularExpression) {
            let match = String(raw[range])
            if let num = match.components(separatedBy: CharacterSet.decimalDigits.inverted)
                .first(where: { !$0.isEmpty }),
               let seconds = Int(num) {
                return seconds
            }
        }
        return nil
    }

    // MARK: - Credential resolution
    //
    // Priority order:
    //   1. Keychain  — most secure; set when the user saves a key via the Settings sheet
    //                  (the setter below migrates to Keychain automatically on first write)
    //   2. Stored property — set by legacy code paths (e.g. ContentView binding)
    //   3. UserDefaults — backward-compat fallback for keys saved before Keychain migration
    //
    // Override `resolvedKey` in subclasses (e.g. ProxyAIService) to provide a
    // different credential type (subscription bearer token) without touching any other logic.

    var apiKey: String = "" {
        didSet {
            // Auto-migrate to Keychain on every external write so the key is secured
            // even if callers still use the legacy `apiKey =` pattern.
            if !apiKey.isEmpty {
                let provider = currentProvider
                KeychainHelper.write(key: provider.keychainKeyName, value: apiKey)
            }
        }
    }

    /// The credential that is actually used for authentication.
    /// Subclasses override this to return a different secret (e.g. proxy bearer token).
    var currentProvider: AIProvider {
        if self is ProxyAIService { return .openAI }
        return AIProvider.selected
    }

    var resolvedModel: String {
        let provider = currentProvider
        let model = UserDefaults.standard.string(forKey: provider.modelDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return model.isEmpty ? provider.defaultModel : model
    }

    var resolvedKey: String {
        let provider = currentProvider
        if let k = KeychainHelper.read(key: provider.keychainKeyName) { return k }
        if !apiKey.isEmpty { return apiKey }
        return UserDefaults.standard.string(forKey: provider.legacyAPIKeyDefaultsKey) ?? ""
    }

    // MARK: - Result type (includes token usage for debug mode)

    struct ChatResult {
        let text:             String
        let promptTokens:     Int
        let completionTokens: Int
        let rawJSON:          String
    }

    // MARK: - Multi-turn chat (full result — used by AgentBrain)

    /// Sends a full messages array and returns text + token usage.
    /// When `hasImage` is true, the last user message is wrapped with a vision content block.
    func chatFull(messages: [[String: Any]], hasImage: Bool, image: UIImage?, jsonMode: Bool = false) async throws -> ChatResult {
        let provider = currentProvider
        guard !resolvedKey.isEmpty else { throw ServiceError.missingAPIKey(provider: provider) }

        var finalMessages = messages

        if hasImage, let img = image,
           let jpeg = img.jpegData(compressionQuality: 0.6) {
            let base64 = jpeg.base64EncodedString()
            if let lastUserIdx = finalMessages.indices.last(where: {
                finalMessages[$0]["role"] as? String == "user"
            }) {
                let queryText = finalMessages[lastUserIdx]["content"] as? String ?? ""
                finalMessages[lastUserIdx] = [
                    "role": "user",
                    "content": [
                        ["type": "image_url",
                         "image_url": ["url": "data:image/jpeg;base64,\(base64)", "detail": "low"]],
                        ["type": "text", "text": queryText]
                    ]
                ]
            }
        }

        var body: [String: Any] = [
            "model": resolvedModel,
            "max_tokens": 250,
            "messages": finalMessages
        ]
        if jsonMode, currentProvider == .openAI {
            body["response_format"] = ["type": "json_object"]
        }

        return try await postFull(body: body)
    }

    /// Convenience shim that returns just the text (kept for callers that don't need token usage).
    func chat(messages: [[String: Any]], hasImage: Bool, image: UIImage?, jsonMode: Bool = false) async throws -> String {
        try await chatFull(messages: messages, hasImage: hasImage, image: image, jsonMode: jsonMode).text
    }

    // MARK: - Episode summarisation (background memory compression)

    /// Compresses a batch of QA episodes into a short summary paragraph.
    /// Keeps the token budget in check as Max accumulates long-term history.
    func summarizeEpisodes(_ episodes: [Memory]) async -> String {
        guard !resolvedKey.isEmpty, !episodes.isEmpty else { return "" }

        let block = episodes.enumerated().map { (i, m) in
            "[\(i + 1)] \(m.text.prefix(300))"
        }.joined(separator: "\n\n")

        let prompt = """
        You are compressing conversation history for an AI assistant's long-term memory.
        Summarise the key points from these \(episodes.count) exchanges into 4–6 concise bullet points.
        Focus on: personal details revealed, important decisions/events, recurring topics, user's interests and goals.
        Write in third person. Be very concise — target under 120 words total.
        Output plain text only, no markdown headers.

        Episodes:
        \(block.prefix(4000))
        """

        let body: [String: Any] = [
            "model": resolvedModel,
            "max_tokens": 200,
            "temperature": 0,
            "messages": [["role": "user", "content": prompt]]
        ]

        return (try? await post(body: body)) ?? ""
    }

    // MARK: - Fact consolidation (deduplication + conflict resolution)
    //
    // Directly implements the "Step 8 — Post Session Memory Consolidation" pattern
    // from the OpenAI context-personalisation cookbook:
    //   inject → reason → distill → consolidate
    //
    // Rules enforced:
    //   1. Remove exact and near-duplicate facts
    //   2. Merge same-topic facts into the clearest single statement
    //   3. On conflict, prefer the more specific / detailed version
    //   4. Never invent information — only restate what's already in the input

    func consolidateFacts(_ facts: [Memory]) async -> [String] {
        guard !resolvedKey.isEmpty, facts.count > 1 else { return facts.map(\.text) }

        let factList = facts.enumerated()
            .map { "[\($0.offset + 1)] \($0.element.text)" }
            .joined(separator: "\n")

        let prompt = """
        You are cleaning up a personal AI assistant's long-term memory.
        Below is a numbered list of facts stored about the user.
        Some may be duplicates, near-duplicates, or in conflict.

        Rules (follow strictly):
        1. Remove exact duplicates — keep one copy only.
        2. Merge near-duplicates (same information, different phrasing) into the single clearest statement.
        3. When two facts conflict, keep the more specific or detailed one.
        4. Never invent, guess, or change any name, number, or relationship.
        5. Preserve all genuinely distinct facts.

        Return ONLY a JSON array of strings — the cleaned fact list. No markdown, no explanation.

        Facts:
        \(factList)
        """

        let body: [String: Any] = [
            "model": resolvedModel,
            "max_tokens": 500,
            "temperature": 0,
            "messages": [["role": "user", "content": prompt]]
        ]

        guard let raw = try? await post(body: body) else { return facts.map(\.text) }

        let cleaned = raw
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data  = cleaned.data(using: .utf8),
              let array = try? JSONDecoder().decode([String].self, from: data),
              !array.isEmpty else {
            return facts.map(\.text)
        }

        return array.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    // MARK: - Retrospective episode mining
    //
    // Scans a batch of past QA episodes to find personal facts and preferences
    // that may have been missed by the per-turn extractor (e.g. because they were
    // mentioned casually, in a different language, or across multiple turns).
    //
    // Broader scope than extractFacts(): looks for habits, interests, opinions,
    // and any personal signal — not just explicitly stated facts.

    func mineFactsFromEpisodes(_ episodes: [Memory]) async -> [String] {
        guard !resolvedKey.isEmpty, !episodes.isEmpty else { return [] }

        // Build a compact readable block (keep episodes brief to stay in budget)
        let block = episodes.map { ep -> String in
            // Episode text format: "User asked: …\nMax answered: …"
            // Trim to 400 chars so a batch of 15 fits comfortably in one call
            return ep.text.prefix(400).description
        }.joined(separator: "\n---\n")

        let prompt = """
        You are scanning past conversation history to build a complete personal profile of the user.

        Review these QA exchanges and extract EVERY personal detail about the user, including:
        • Names of family members, friends, pets (e.g. "User's mother is named X")
        • Relationships (wife, father, sibling, friend)
        • Preferences, interests, hobbies, favourite things
        • Occupation, location, daily routines, goals
        • Opinions, values, habits
        • Any personal fact explicitly mentioned or clearly implied

        Format: third-person short statements.
        Good: "User's mother is named Rachel", "User prefers window seats", "User enjoys hiking"
        Bad: "User said something about family", "Max mentioned..."

        Return ONLY a JSON array of strings. Return [] if nothing personal is found.
        No markdown, no explanation, no numbering.

        Episodes:
        \(block.prefix(6000))
        """

        let body: [String: Any] = [
            "model": resolvedModel,
            "max_tokens": 500,
            "temperature": 0,
            "messages": [["role": "user", "content": prompt]]
        ]

        guard let raw = try? await post(body: body) else { return [] }

        let cleaned = raw
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data  = cleaned.data(using: .utf8),
              let array = try? JSONDecoder().decode([String].self, from: data) else { return [] }

        return array.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    // MARK: - Intent classifier
    //
    // Replaces ALL keyword-based routing. Runs in parallel with memory retrieval
    // so it adds no extra latency to the main turn.
    //
    // Returns one of four intents:
    //   .search  — user explicitly wants a live web search
    //   .news    — user wants current news / recent events
    //   .vision  — user wants to analyse the active image
    //   .chat    — everything else (normal conversation)
    //
    // Using GPT for this prevents false positives like "I look forward to seeing you"
    // triggering vision mode, or "I'm searching for meaning" triggering Serper.

    enum MessageIntent: String {
        case chat, search, news, vision
    }

    func classifyIntent(query: String, hasImage: Bool) async -> MessageIntent {
        guard !resolvedKey.isEmpty else { return hasImage ? .vision : .chat }

        let imageCtx = hasImage
            ? "The user has an active photo/snapshot open."
            : "No image is currently active."

        let prompt = """
        \(imageCtx)
        Classify the user message below into exactly ONE category. Reply with a single word only.

        Categories:
        - search   → user explicitly wants to search the web (e.g. "search for X", "find online", "google X")
        - news     → user explicitly wants current news or recent events (e.g. "latest news", "what's happening")
        - vision   → user wants to analyse, describe, or ask about the active image/photo
        - chat     → everything else: questions, conversation, facts, memory, help

        Important: only reply "search" or "news" if the user clearly wants live web results, not just using the word "search" in a sentence. Only reply "vision" if an image is active AND the user is asking about it.

        Message: "\(query.prefix(250))"
        Category:
        """

        let body: [String: Any] = [
            "model": resolvedModel,
            "max_tokens": 5,
            "temperature": 0,
            "messages": [["role": "user", "content": prompt]]
        ]

        let raw = ((try? await post(body: body)) ?? "chat")
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        print("[OpenAI] Intent: '\(raw)' for '\(query.prefix(40))'")

        if raw.contains("news")   { return .news   }
        if raw.contains("search") { return .search  }
        if raw.contains("vision") { return hasImage ? .vision : .chat }
        return .chat
    }

    /// Small AI gate used before auto-capturing a photo for text/voice queries.
    /// Returns true only when the user is explicitly asking for visual understanding.
    func shouldAutoCaptureImage(for query: String) async -> Bool {
        guard !resolvedKey.isEmpty else { return false }

        let prompt = """
        Decide whether this user message REQUIRES camera/image analysis.
        Reply with exactly one word: yes or no.

        Answer "yes" only if the user is asking about what they are seeing, what is in front of them, or to describe/analyze "this" visually.
        Answer "no" for normal chat, memory questions, search/news requests, coding/help tasks, or anything that does not clearly require visual input.

        Message: "\(query.prefix(250))"
        Decision:
        """

        let body: [String: Any] = [
            "model": resolvedModel,
            "max_tokens": 3,
            "temperature": 0,
            "messages": [["role": "user", "content": prompt]]
        ]

        let raw = ((try? await post(body: body)) ?? "no")
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return raw.contains("yes")
    }

    // MARK: - Visual Memory agent
    //
    // Dedicated agent that analyses a snapshot being saved as a "memory".
    // Returns a rich description, short title, and searchable tags so memories
    // can be retrieved later with queries like "what was that café I saw yesterday?"

    struct VisualMemoryAnalysis {
        let summary:     String    // 5-8 word title, e.g. "Cozy café on Dizengoff street"
        let description: String    // 1-2 sentence rich description
        let tags:        [String]  // 3-8 searchable tags
        let objects:     [String]  // object inventory: ["keys on coffee table", "remote on sofa", …]
    }

    /// Analyze an image for saving as a visual memory.
    /// Returns a rich description, title, searchable tags, AND a complete object inventory.
    /// The object inventory is the key feature that allows queries like "where are my keys?".
    func analyzeVisualMemory(image: UIImage,
                             locationName: String?,
                             userFacts: String? = nil) async -> VisualMemoryAnalysis {
        let fallback = VisualMemoryAnalysis(summary: "Saved memory", description: "", tags: [], objects: [])
        guard !resolvedKey.isEmpty,
              let jpeg = image.jpegData(compressionQuality: 0.65) else { return fallback }

        let base64   = jpeg.base64EncodedString()
        let locCtx   = locationName.map { " Location: \($0)." } ?? ""
        let factsCtx = userFacts.map {
            "\n\nKNOWN FACTS ABOUT THE USER — use them to identify subjects by name " +
            "(e.g. if you see their dog and know its name, use it):\n\($0)"
        } ?? ""

        let prompt = """
        You are saving a photo as a searchable personal memory.\(locCtx)\(factsCtx)

        Analyze this image and return ONLY valid JSON with these exact fields:
        {
          "summary": "A 5-8 word memorable title",
          "description": "1-2 sentences of what makes this moment special — use known names where applicable",
          "tags": ["tag1", "tag2", "tag3"],
          "objects": ["item at location", "item2 at location2"]
        }

        TAGS: 3-8 lowercase words for searching (place type, activity, mood, people/pet names, colors).
        Example tags for a café: ["café", "coffee", "indoor", "cozy", "dizengoff"]

        OBJECTS — THIS IS CRITICAL: List every distinct physical object visible in the image with its location.
        Format each item as: "<object name> <location in frame>" — be specific about WHERE it is.
        Examples: "TV remote on the right sofa cushion", "keys hanging on the door hook",
                  "glasses on the nightstand", "laptop on the desk", "coffee mug on the table",
                  "book on the shelf", "phone next to the keyboard", "dog on the floor",
                  "water bottle on the counter", "charger on the floor near the wall"
        Include ALL notable objects — furniture, electronics, food, clothing, personal items, pets, people.
        Minimum 5 objects if visible. Maximum 20.

        No markdown, no explanation — only the JSON object.
        """

        let messages: [[String: Any]] = [[
            "role": "user",
            "content": [
                ["type": "image_url",
                 "image_url": ["url": "data:image/jpeg;base64,\(base64)", "detail": "high"]],
                ["type": "text", "text": prompt]
            ]
        ]]

        let body: [String: Any] = [
            "model": resolvedModel,
            "max_tokens": 500,
            "temperature": 0,
            "messages": messages
        ]

        guard let raw = try? await post(body: body) else { return fallback }

        let cleaned = raw
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return fallback
        }

        let objects = (json["objects"] as? [String]) ?? []
        print("[VisualMemory] Object inventory: \(objects.count) items — \(objects.prefix(3).joined(separator: ", "))")

        return VisualMemoryAnalysis(
            summary:     (json["summary"]     as? String)   ?? "Saved memory",
            description: (json["description"] as? String)   ?? "",
            tags:        (json["tags"]        as? [String]) ?? [],
            objects:     objects
        )
    }

    // MARK: - Image-to-search-query (used when user requests search with active image)
    //
    // Returns a concise description suitable as a Serper search query.
    // E.g. photo of a white poodle → "white poodle dog breed"
    // E.g. photo of a product → "Sony WH-1000XM5 headphones"

    func describeImageForSearch(_ image: UIImage) async -> String {
        guard !resolvedKey.isEmpty else { return "" }
        guard let jpeg   = image.jpegData(compressionQuality: 0.5) else { return "" }
        let base64 = jpeg.base64EncodedString()

        let messages: [[String: Any]] = [
            [
                "role": "user",
                "content": [
                    ["type": "image_url",
                     "image_url": ["url": "data:image/jpeg;base64,\(base64)", "detail": "low"]],
                    ["type": "text",
                     "text": "Describe this image in 5-8 words suitable as a Google search query. Output only the search query, no punctuation."]
                ]
            ]
        ]

        let body: [String: Any] = [
            "model": resolvedModel,
            "max_tokens": 30,
            "temperature": 0,
            "messages": messages
        ]

        let desc = (try? await post(body: body)) ?? ""
        print("[OpenAI] Image search description: '\(desc)'")
        return desc.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Country extraction micro-agent
    //
    // Ultra-cheap single call: given free-text (query + optional answer), return the
    // ISO-3166-1 alpha-2 country code for where the user is located.
    // Returns nil quickly when nothing location-related is present.

    func extractCountryCode(from text: String) async -> String? {
        guard !resolvedKey.isEmpty, !text.isEmpty else { return nil }

        let prompt = """
        You are a location detector. Given this text, return ONLY the ISO-3166-1 alpha-2 country code \
        (lowercase, 2 letters) for the country the user is located in or is asking about locally. \
        If no clear country is mentioned or implied, return the word "none". \
        No explanation, no punctuation — just the 2-letter code or "none".

        Text: \(text.prefix(300))
        """

        let body: [String: Any] = [
            "model": resolvedModel,
            "max_tokens": 5,
            "temperature": 0,
            "messages": [["role": "user", "content": prompt]]
        ]

        guard let raw = try? await post(body: body) else { return nil }
        let code = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Must be exactly 2 letters and not "none"
        guard code.count == 2, code != "no" else { return nil }
        print("[OpenAI] Extracted country code: \(code)")
        return code
    }

    // MARK: - Fact extraction (background pass after every turn)

    func extractFacts(userMessage: String, assistantMessage: String) async -> [String] {
        guard !resolvedKey.isEmpty else { return [] }

        let prompt = """
        You are a memory extractor for a personal AI assistant.
        Look at this single exchange and return ONLY a JSON array of short factual strings about the user — \
        names of people/pets, relationships, preferences, interests, goals, location, occupation, or any \
        personal detail they revealed. Use third-person format, e.g. "User's wife is named Chen". \
        Return [] if nothing personal was disclosed. No explanation, no markdown — just the JSON array.

        User: \(userMessage)
        Assistant: \(assistantMessage)
        """

        let body: [String: Any] = [
            "model": resolvedModel,
            "max_tokens": 120,
            "temperature": 0,
            "messages": [["role": "user", "content": prompt]]
        ]

        guard let raw = try? await post(body: body) else { return [] }

        let cleaned = raw
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data  = cleaned.data(using: .utf8),
              let array = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return array.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    // MARK: - Quick single-turn (photo Q&A without brain context)

    func analyzePhoto(_ image: UIImage, question: String) async throws -> String {
        let provider = currentProvider
        guard !resolvedKey.isEmpty else { throw ServiceError.missingAPIKey(provider: provider) }
        guard let jpeg = image.jpegData(compressionQuality: 0.7) else {
            throw ServiceError.imageEncodingFailed
        }

        let body: [String: Any] = [
            "model": resolvedModel,
            "max_tokens": 150,
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "image_url",
                     "image_url": ["url": "data:image/jpeg;base64,\(jpeg.base64EncodedString())",
                                   "detail": "low"]],
                    ["type": "text",
                     "text": "You are Max, an AI in smart glasses. Answer in 1-2 sentences. \(question)"]
                ]
            ]]
        ]

        return try await post(body: body)
    }

    // MARK: - Shared HTTP layer (returns text only)

    private func post(body: [String: Any]) async throws -> String {
        try await postFull(body: body).text
    }

    // MARK: - Shared HTTP layer (returns full result with token usage)
    //
    // `postFull` is internal (not private) so ProxyAIService can override just this
    // one method to swap the transport layer while inheriting all prompt-building logic.

    func postFull(body: [String: Any]) async throws -> ChatResult {
        let provider = currentProvider
        if provider == .gemini, let remaining = Self.currentGeminiCooldownSeconds() {
            throw ServiceError.rateLimited(provider: provider, retryAfterSeconds: remaining)
        }
        let url = provider.chatCompletionsURL
        var req = URLRequest(url: url)
        req.httpMethod  = "POST"
        req.timeoutInterval = 25
        req.setValue("Bearer \(resolvedKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json",  forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        func executeRequest() async throws -> (Data, URLResponse) {
            try await URLSession.shared.data(for: req)
        }

        var (data, response) = try await executeRequest()

        // Gemini occasionally returns transient 503 (high demand). Retry once with
        // a short backoff to reduce user-visible failures without masking real issues.
        if provider == .gemini,
           let http = response as? HTTPURLResponse,
           http.statusCode == 503 {
            try? await Task.sleep(nanoseconds: 800_000_000)
            let retried = try await executeRequest()
            data = retried.0
            response = retried.1
        }

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            if let raw = String(data: data, encoding: .utf8) {
                print("[\(provider.displayName)] HTTP \(http.statusCode): \(raw)")
            }
            if provider == .gemini, http.statusCode == 429 {
                let retryAfter = Self.parseRetryAfterSeconds(from: data)
                if let retryAfter {
                    Self.setGeminiRateLimitCooldown(seconds: retryAfter)
                }
                throw ServiceError.rateLimited(provider: provider, retryAfterSeconds: retryAfter)
            }
            throw ServiceError.httpError(http.statusCode, provider: provider)
        }

        let rawJSON = String(data: data, encoding: .utf8) ?? ""

        guard let parsed  = try? JSONDecoder().decode(ChatResponse.self, from: data),
              let content = parsed.choices.first?.message.content else {
            throw ServiceError.decodingFailed
        }

        return ChatResult(
            text:             content.trimmingCharacters(in: .whitespacesAndNewlines),
            promptTokens:     parsed.usage?.promptTokens     ?? 0,
            completionTokens: parsed.usage?.completionTokens ?? 0,
            rawJSON:          rawJSON
        )
    }

    // MARK: - Errors

    enum ServiceError: LocalizedError {
        case missingAPIKey(provider: AIProvider)
        case imageEncodingFailed
        case httpError(Int, provider: AIProvider)
        case rateLimited(provider: AIProvider, retryAfterSeconds: Int?)
        case decodingFailed

        var errorDescription: String? {
            switch self {
            case .missingAPIKey(let provider):
                return "Add your \(provider.displayName) API key in Settings."
            case .imageEncodingFailed: return "Failed to encode the camera frame."
            case .httpError(401, let provider):
                if provider == .gemini {
                    return "Invalid Gemini API key."
                }
                return "Invalid OpenAI API key — check platform.openai.com/api-keys."
            case .httpError(429, let provider):
                if provider == .gemini {
                    return "Gemini quota exceeded — check your Google AI usage limits."
                }
                return "OpenAI quota exceeded — add credits at platform.openai.com/billing."
            case .rateLimited(let provider, let retryAfter):
                if let retryAfter, retryAfter > 0 {
                    return "\(provider.displayName) rate limit reached. Please try again in about \(retryAfter) seconds."
                }
                return "\(provider.displayName) rate limit reached. Please try again shortly."
            case .httpError(503, let provider):
                if provider == .gemini {
                    return "Gemini is temporarily overloaded right now. Please try again in a moment."
                }
                return "\(provider.displayName) is temporarily unavailable. Please try again."
            case .httpError(let c, let provider):
                return "\(provider.displayName) error \(c) — please try again."
            case .decodingFailed:      return "Could not read the AI response."
            }
        }
    }

    // MARK: - Response models (internal so ProxyAIService can decode the same format)

    struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String }
            let message: Message
        }
        struct Usage: Decodable {
            let promptTokens:     Int
            let completionTokens: Int
            enum CodingKeys: String, CodingKey {
                case promptTokens     = "prompt_tokens"
                case completionTokens = "completion_tokens"
            }
        }
        let choices: [Choice]
        let usage:   Usage?
    }
}

// MARK: - AIServiceProtocol conformance
//
// OpenAIService already implements every required method — this declaration is the
// only addition needed. No code duplication, no wrapper, no body.

extension OpenAIService: AIServiceProtocol {}

// MARK: - LocalAIService typealias
//
// In the Open Core architecture, OpenAIService IS the OSS (local) implementation:
// it calls OpenAI directly using credentials resolved from device Keychain / UserDefaults.
// ServiceFactory returns this type for the OSS build target.

typealias LocalAIService = OpenAIService
