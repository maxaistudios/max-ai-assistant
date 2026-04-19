import Foundation
import Combine
import UIKit

// MARK: - Debug info (captured during each AI turn)

struct DebugInfo {
    let systemPrompt:     String
    let factsCount:       Int
    let episodesCount:    Int
    let summariesCount:   Int
    let rawResponse:      String
    let processingMs:     Int
    let hasImage:         Bool
    let promptTokens:     Int
    let completionTokens: Int
}

// MARK: - Chat message (UI model)

struct ChatMessage: Identifiable {
    let id        = UUID()
    let role:       Role
    let content:    String
    let timestamp:  Date
    var hasImage:   Bool              = false
    var followUps:  [String]          = []
    var debugInfo:  DebugInfo?        = nil
    var searchResults: [SerperResult] = []
    /// Visual memories recalled for this turn — shown as tappable thumbnails in the chat bubble.
    var visualMemories: [VisualMemory] = []

    enum Role { case user, assistant }
}

// MARK: - AgentBrain

/// Central AI orchestrator.
///
/// Every turn:
///   1. Retrieves all three memory tiers (facts / episodes / summaries)
///   2. Builds system prompt: soul + memories + preferences + recent history
///   3. Calls gpt-4o-mini in JSON mode → {answer, followUps}
///   4. Stores Q&A + extracted facts as separate searchable memories
///   5. Triggers background episode summarisation when buffer grows large
@MainActor
final class AgentBrain: ObservableObject {

    // MARK: - Singleton
    //
    // The shared instance is created with ServiceFactory defaults so the correct
    // backend is selected automatically at compile time based on the build target.
    // In tests, create a fresh AgentBrain(aiService: MockAIService(), ...) directly.

    static let shared = AgentBrain()

    // MARK: - Injected services

    private let aiService:     any AIServiceProtocol
    private let searchService: any SearchServiceProtocol

    // MARK: - Init (Dependency-Injected)
    //
    // Default parameters pull from ServiceFactory so no call-site changes are needed
    // for the shared singleton, while tests and previews can inject mock services freely.

    init(
        aiService:     any AIServiceProtocol     = ServiceFactory.makeAIService(),
        searchService: any SearchServiceProtocol = ServiceFactory.makeSearchService()
    ) {
        self.aiService     = aiService
        self.searchService = searchService
        loadPreferences()
        print("[AgentBrain] Init. Preferences: \(preferences)")
        print("[AgentBrain] Memory count: \(MemoryStore.shared.count)")
    }

    // MARK: - Published

    @Published var isThinking:   Bool          = false
    @Published var chatHistory: [ChatMessage]  = []

    // MARK: - Short-term context (RAM only, cleared per session)

    private var shortTerm:      [ConversationTurn] = []
    private let shortTermLimit  = 12

    // MARK: - Preferences (UserDefaults)

    private(set) var preferences: [String: String] = [:]
    private let prefsKey = "max_agent_preferences_v2"

    // MARK: - Structured response from GPT

    private struct GPTResponse: Decodable {
        let answer:    String
        let followUps: [String]
    }

    // MARK: - Main entry point

    func respond(to query: String, image: UIImage? = nil, debugMode: Bool = false) async throws -> String {
        isThinking = true
        defer { isThinking = false }

        chatHistory.append(ChatMessage(
            role: .user, content: query, timestamp: Date(), hasImage: image != nil
        ))

        // ── Classify intent + retrieve memory in parallel (no extra latency) ────────
        // GPT classifies the message instead of brittle keyword matching.
        // "I look forward to seeing you" → .chat, not .vision
        // "I'm searching for meaning" → .chat, not .search
        async let intentTask  = aiService.classifyIntent(query: query, hasImage: image != nil)
        async let memCtxTask  = Task.detached(priority: .userInitiated) {
            MemoryStore.shared.context(for: query, topK: 4)
        }.value

        let intent = await intentTask
        let memCtx = await memCtxTask

        let wantsVision = image != nil && intent == .vision
        let wantsSearch = intent == .search || intent == .news
        let wantsNews   = intent == .news

        print("[AgentBrain] Query: '\(query.prefix(50))' | \(memCtx.facts.count)f/\(memCtx.episodes.count)e/\(memCtx.summaries.count)s | intent: \(intent.rawValue)")

        // ── Optional: Serper web search / news ───────────────────────────────────
        var searchResults: [SerperResult] = []
        if wantsSearch {
            let gl = await resolveCountryCode(query: query, facts: memCtx.facts)

            // When an image is present, describe it first so we get meaningful results
            // rather than searching for words like "this" or "online"
            let effectiveQuery: String
            if let img = image {
                let imageDesc = await aiService.describeImageForSearch(img)
                if !imageDesc.isEmpty {
                    // Merge image description with any explicit text the user typed
                    // e.g. user said "search online" + image of a poodle → "white poodle dog breed"
                    let userExtra = cleanSearchQuery(query)
                    effectiveQuery = isGenericSearchPhrase(userExtra)
                        ? imageDesc
                        : "\(imageDesc) \(userExtra)"
                } else {
                    effectiveQuery = cleanSearchQuery(query)
                }
            } else {
                effectiveQuery = cleanSearchQuery(query)
            }

            if !effectiveQuery.isEmpty {
                searchResults = await searchService.search(
                    query:  effectiveQuery,
                    isNews: wantsNews,
                    gl:     gl,
                    num:    6
                )
                print("[AgentBrain] Search '\(effectiveQuery.prefix(40))' → \(searchResults.count) results (gl=\(gl))")
            } else {
                print("[AgentBrain] Search skipped — query resolved to empty string")
            }
        }

        // ── Query-targeted visual memory lookup ───────────────────────────────────
        // Two-pass search: first direct object hit, then broad keyword match.
        // Returns both a text context block and the matched memory objects for UI thumbnails.
        let vmResult       = VisualMemoryStore.shared.contextForQuery(query)
        let vmQueryContext = vmResult?.context
        let vmMemories     = vmResult?.memories ?? []

        // ── Build messages array ──────────────────────────────────────────────────
        let (messages, systemPrompt) = buildMessages(
            query: query, image: image, context: memCtx,
            searchResults: searchResults, vmQueryContext: vmQueryContext
        )

        // ── Call GPT ─────────────────────────────────────────────────────────────
        let startTime = Date()
        let result = try await aiService.chatFull(
            messages: messages,
            hasImage: wantsVision,
            image: image,
            jsonMode: true
        )
        let processingMs = Int(-startTime.timeIntervalSinceNow * 1000)

        let (answer, followUps) = parseGPTResponse(result.text)

        // ── Build debug info ──────────────────────────────────────────────────────
        var dbg: DebugInfo? = nil
        if debugMode {
            dbg = DebugInfo(
                systemPrompt:     systemPrompt,
                factsCount:       memCtx.facts.count,
                episodesCount:    memCtx.episodes.count,
                summariesCount:   memCtx.summaries.count,
                rawResponse:      result.rawJSON,
                processingMs:     processingMs,
                hasImage:         wantsVision,
                promptTokens:     result.promptTokens,
                completionTokens: result.completionTokens
            )
        }

        chatHistory.append(ChatMessage(
            role:           .assistant,
            content:        answer,
            timestamp:      Date(),
            followUps:      followUps,
            debugInfo:      dbg,
            searchResults:  searchResults,
            visualMemories: vmMemories
        ))

        // ── Short-term window ─────────────────────────────────────────────────────
        shortTerm.append(ConversationTurn(role: "user",      content: query,  hasImage: image != nil))
        shortTerm.append(ConversationTurn(role: "assistant", content: answer))
        if shortTerm.count > shortTermLimit * 2 {
            shortTerm = Array(shortTerm.suffix(shortTermLimit * 2))
        }

        // ── Background: store memories, extract facts, maybe summarise ────────────
        let querySnapshot   = query
        let answerSnapshot  = answer
        let vision          = wantsVision
        // Capture the injected service so background tasks use the same backend
        // as the main turn (avoids falling back to OpenAIService.shared in detached Tasks).
        let capturedService = aiService
        Task.detached(priority: .background) {
            // 1. Store this exchange as an episode
            AgentBrain.storeMemories(query: querySnapshot, answer: answerSnapshot, vision: vision)
            // 2. Extract facts from this exchange immediately
            await AgentBrain.extractAndStoreFactsWithAI(
                query: querySnapshot, answer: answerSnapshot, using: capturedService
            )
            // 3. Retrospective mining — scan older episodes for facts/prefs missed by (2)
            //    Runs every ~10 new episodes; catches things mentioned casually or in other languages
            if MemoryStore.shared.needsEpisodeMining {
                await AgentBrain.runEpisodeMining(using: capturedService)
            }
            // 4. Summarise old episodes when the buffer is large
            if MemoryStore.shared.needsSummarization {
                await AgentBrain.runSummarization(using: capturedService)
            }
            // 5. Deduplicate facts when they accumulate
            if MemoryStore.shared.needsFactConsolidation {
                await MemoryStore.shared.consolidateFacts(using: capturedService)
            }
        }

        extractPreferences(from: query)

        return answer
    }

    // MARK: - Forwarding helpers
    //
    // Thin pass-throughs that let ContentView call AI operations through AgentBrain
    // rather than directly on OpenAIService.shared, ensuring the correct service
    // implementation is used regardless of the active build target.

    /// Analyses an image for "Remember This" without going through a full conversation turn.
    func analyzeVisualMemory(
        image:        UIImage,
        locationName: String?,
        userFacts:    String?
    ) async -> OpenAIService.VisualMemoryAnalysis {
        await aiService.analyzeVisualMemory(image: image, locationName: locationName, userFacts: userFacts)
    }

    // MARK: - Session management

    func clearSession() {
        shortTerm   = []
        chatHistory = []
        print("[AgentBrain] Session cleared")
    }

    // MARK: - Message building

    private func buildMessages(
        query: String,
        image: UIImage?,
        context: MemoryContext,
        searchResults: [SerperResult] = [],
        vmQueryContext: String? = nil
    ) -> ([[String: Any]], String) {
        let systemPrompt = MaxSoul.buildSystemPrompt(
            preferences: preferences,
            context: context,
            recentTurns: shortTerm,
            visualMemoriesContext: VisualMemoryStore.shared.contextForAI()
        )

        var messages: [[String: Any]] = [["role": "system", "content": systemPrompt]]

        // Inject query-matched visual memories as a high-priority block directly
        // before the conversation history so it's the most salient context for GPT.
        if let vmCtx = vmQueryContext {
            messages.append([
                "role": "system",
                "content": "⚠️ CONFIRMED VISUAL MEMORY MATCH FOR THIS QUERY:\n" +
                           "The user is asking about something they actually photographed and saved. " +
                           "Answer YES confidently based on this. Do NOT say you cannot see past activities.\n\n" +
                           vmCtx
            ])
            print("[AgentBrain] Visual memory context injected for query")
        } else {
            print("[AgentBrain] No visual memory match for query")
        }

        // Inject search results as a system context block so GPT can synthesise them
        if !searchResults.isEmpty {
            let block = searchResults.prefix(6).enumerated().map { (i, r) in
                "[\(i+1)] \(r.title)\nSource: \(r.sourceName)\n\(r.snippet ?? "")"
            }.joined(separator: "\n\n")
            messages.append([
                "role": "system",
                "content": "LIVE SEARCH RESULTS — use these to answer the user. Cite sources naturally:\n\n\(block)"
            ])
        }

        for turn in shortTerm.suffix(8) {
            messages.append(["role": turn.role, "content": turn.content])
        }

        messages.append(["role": "user", "content": query])
        return (messages, systemPrompt)
    }

    /// Full country-code resolution pipeline (fast → smart → ask):
    ///
    /// 1. Check stored facts + query text  (zero cost, always runs)
    /// 2. GPT micro-agent on query text    (only when step 1 misses; ~1 token call)
    /// 3. Store result as a fact for future turns
    /// 4. If still unknown → default "us" and queue a polite ask on the next turn
    private func resolveCountryCode(query: String, facts: [Memory]) async -> String {
        // Step 1 — fast static lookup across facts + query text
        let fastCode = SerperService.countryCode(from: facts, queryHint: query)
        if fastCode != "us" || SerperService.hasKnownLocation(from: facts) {
            return fastCode   // confident result from known data
        }

        // Step 2 — GPT micro-agent: extract country from the raw query text
        if let aiCode = await aiService.extractCountryCode(from: query) {
            // Persist as a fact so we don't repeat this call next time
            let factText = "User's country code for search is \(aiCode)"
            MemoryStore.shared.add(text: factText, tags: ["fact"])
            print("[AgentBrain] Country code extracted by AI and stored: \(aiCode)")
            return aiCode
        }

        // Step 3 — No location found: queue a one-time location question for next idle turn
        if !locationAsked {
            locationAsked = true
            Task { @MainActor in
                // Small delay so the current answer renders first
                try? await Task.sleep(nanoseconds: 800_000_000)
                let prompt = ChatMessage(
                    role:      .assistant,
                    content:   "To give you more relevant local results, where are you located? (city or country)",
                    timestamp: Date(),
                    followUps: ["Israel", "United States", "United Kingdom"]
                )
                chatHistory.append(prompt)
            }
        }

        return "us"  // safe default
    }

    /// Prevents asking for location more than once per session.
    private var locationAsked = false

    /// Strips search-intent preamble and returns the core query subject.
    /// Falls back to the original text if stripping would leave nothing meaningful.
    private func cleanSearchQuery(_ raw: String) -> String {
        var q = raw.trimmingCharacters(in: .whitespaces)

        // Remove leading intent phrases
        let prefixes = [
            "search online for ", "search for ", "search online", "search ",
            "google ", "look up ", "find online ", "find me ",
            "what's the latest on ", "what is the latest on ",
            "latest news about ", "news about ", "news on ",
            "tell me about ", "show me "
        ]
        let lower = q.lowercased()
        for prefix in prefixes {
            if lower.hasPrefix(prefix) {
                let stripped = String(q.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                // Only use stripped version if it's a real query (≥ 2 non-trivial words)
                if !isGenericSearchPhrase(stripped) {
                    return stripped
                }
                break
            }
        }
        return isGenericSearchPhrase(q) ? "" : q
    }

    /// Returns true when the text is too vague to be a useful Serper query.
    /// e.g. "online", "this", "it", "something" — stripped leftovers that mean nothing.
    private func isGenericSearchPhrase(_ text: String) -> Bool {
        let trivial: Set<String> = [
            "online", "this", "it", "that", "something", "anything",
            "info", "information", "more", "details", "here"
        ]
        let words = text.lowercased().split(separator: " ").map(String.init)
        if words.isEmpty { return true }
        // Consider generic if ALL words are trivial filler
        return words.allSatisfy { trivial.contains($0) }
    }

    // MARK: - JSON parsing

    private func parseGPTResponse(_ raw: String) -> (answer: String, followUps: [String]) {
        if let data   = raw.data(using: .utf8),
           let parsed = try? JSONDecoder().decode(GPTResponse.self, from: data) {
            print("[AgentBrain] JSON parsed OK. followUps: \(parsed.followUps.count)")
            return (parsed.answer, Array(parsed.followUps.prefix(3)))
        }
        let stripped = raw
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```",     with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let data   = stripped.data(using: .utf8),
           let parsed = try? JSONDecoder().decode(GPTResponse.self, from: data) {
            return (parsed.answer, Array(parsed.followUps.prefix(3)))
        }
        print("[AgentBrain] JSON parse failed — raw: \(raw.prefix(80))")
        return (raw, [])
    }

    // MARK: - Memory storage (static → safe from Task.detached)

    private nonisolated static func storeMemories(query: String, answer: String, vision: Bool) {
        let tags = vision ? ["qa", "vision"] : ["qa"]
        MemoryStore.shared.add(text: "User asked: \(query)\nMax answered: \(answer)", tags: tags)
    }

    private nonisolated static func extractAndStoreFactsWithAI(
        query: String,
        answer: String,
        using aiService: any AIServiceProtocol
    ) async {
        let facts = await aiService.extractFacts(
            userMessage: query,
            assistantMessage: answer
        )
        for fact in facts {
            MemoryStore.shared.add(text: fact, tags: ["fact"])
            print("[AgentBrain] AI-extracted fact: \(fact)")
        }
    }

    /// Scans episodes not yet reviewed by the fact extractor and pulls out
    /// any personal facts, preferences, or interests that were missed.
    /// Key use-case: "my mother's name is X" mentioned casually in a previous session
    /// was stored as an episode but never elevated to a fact — mining catches it.
    private nonisolated static func runEpisodeMining(using aiService: any AIServiceProtocol) async {
        let episodes = MemoryStore.shared.unmindedEpisodes
        guard !episodes.isEmpty else {
            MemoryStore.shared.recordMiningCompleted()
            return
        }
        print("[AgentBrain] Mining \(episodes.count) episodes for facts/preferences…")
        let mined = await aiService.mineFactsFromEpisodes(episodes)
        var stored = 0
        for fact in mined {
            MemoryStore.shared.add(text: fact, tags: ["fact"])
            stored += 1
            print("[AgentBrain] Mined: \(fact)")
        }
        MemoryStore.shared.recordMiningCompleted()
        print("[AgentBrain] Mining complete — \(stored) facts elevated ✅")
    }

    /// Compresses the oldest episode batch into a summary chapter, then removes
    /// those episodes from the rolling buffer.  Keeps long-term context without
    /// growing the per-turn token count.
    /// Convenience overload for call-sites (e.g. ContentView) that don't hold a
    /// direct service reference. Resolves the active service from ServiceFactory.
    nonisolated static func runSummarization() async {
        await runSummarization(using: ServiceFactory.makeAIService())
    }

    nonisolated static func runSummarization(using aiService: any AIServiceProtocol) async {
        let episodes = MemoryStore.shared.oldestEpisodesForSummary()
        guard !episodes.isEmpty else { return }
        print("[AgentBrain] Summarising \(episodes.count) episodes…")
        let summaryText = await aiService.summarizeEpisodes(episodes)
        guard !summaryText.isEmpty else { return }
        MemoryStore.shared.commitSummary(text: summaryText, replacingFirstN: episodes.count)
        print("[AgentBrain] Summarisation complete ✅")
    }

    // MARK: - Preference extraction (MainActor)

    private func extractPreferences(from query: String) {
        let lower = query.lowercased()
        var updated = preferences

        for prefix in ["my name is ", "call me ", "i'm called ", "i am called "] {
            if lower.contains(prefix),
               let rest = lower.components(separatedBy: prefix).last {
                let name = rest.components(separatedBy: CharacterSet(charactersIn: " .,!?"))
                    .first?
                    .trimmingCharacters(in: .punctuationCharacters) ?? ""
                if name.count > 1 && name.count < 30 {
                    updated["userName"] = name.capitalized
                }
            }
        }

        if lower.contains("be more detailed") || lower.contains("give me more detail") {
            updated["detailLevel"] = "detailed"
        } else if lower.contains("keep it short") || lower.contains("be brief") {
            updated["detailLevel"] = "brief"
        }

        if lower.contains("speak to me in ") || lower.contains("reply in "),
           let rest = lower.components(separatedBy: lower.contains("speak to me in ") ? "speak to me in " : "reply in ").last {
            let lang = rest.components(separatedBy: " ").first ?? ""
            if lang.count > 1 { updated["preferredLanguage"] = lang.capitalized }
        }

        if updated != preferences {
            preferences = updated
            savePreferences()
        }
    }

    // MARK: - Persistence

    func savePreferences() {
        UserDefaults.standard.set(preferences, forKey: prefsKey)
    }

    private func loadPreferences() {
        let oldKey = "max_agent_preferences"
        if let old = UserDefaults.standard.dictionary(forKey: oldKey) as? [String: String], !old.isEmpty {
            preferences = old
            UserDefaults.standard.set(preferences, forKey: prefsKey)
            UserDefaults.standard.removeObject(forKey: oldKey)
            return
        }
        preferences = UserDefaults.standard.dictionary(forKey: prefsKey) as? [String: String] ?? [:]
    }

    func setPreference(key: String, value: String) {
        preferences[key] = value
        savePreferences()
    }

    func removePreference(key: String) {
        preferences.removeValue(forKey: key)
        savePreferences()
    }
}
