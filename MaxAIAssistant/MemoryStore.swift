import Foundation
import NaturalLanguage

// MARK: - Memory entry

struct Memory: Codable, Identifiable {
    let id:        UUID
    let text:      String
    let embedding: [Double]
    let timestamp: Date
    let tags:      [String]

    init(text: String, embedding: [Double], tags: [String] = []) {
        id        = UUID()
        self.text      = text
        self.embedding = embedding
        self.timestamp = Date()
        self.tags      = tags
    }
}

// MARK: - Summary entry (Tier 3 — compressed episode history)

struct MemorySummary: Codable, Identifiable {
    let id:           UUID
    let text:         String   // AI-compressed summary
    let episodeCount: Int      // how many QA pairs this covers
    let timestamp:    Date

    init(text: String, episodeCount: Int) {
        id           = UUID()
        self.text         = text
        self.episodeCount = episodeCount
        timestamp    = Date()
    }
}

// MARK: - Memory context (passed to MaxSoul each turn)

struct MemoryContext {
    let facts:    [Memory]         // personal profile, always in prompt
    let episodes: [Memory]         // relevant QA, semantic search
    let summaries:[MemorySummary]  // compressed history, always in prompt

    var isEmpty: Bool { facts.isEmpty && episodes.isEmpty && summaries.isEmpty }
}

// MARK: - Conversation turn (short-term window, RAM only)

struct ConversationTurn: Codable {
    let role:      String
    let content:   String
    let timestamp: Date
    var hasImage:  Bool

    init(role: String, content: String, hasImage: Bool = false) {
        self.role      = role
        self.content   = content
        self.timestamp = Date()
        self.hasImage  = hasImage
    }
}

// MARK: - MemoryStore  (tiered, thread-safe)
//
//  Tier 1 — Facts      (max_facts.json)
//      Personal profile — deduplicated on write, always in prompt (≤25)
//      Sources: per-turn AI extraction + retrospective episode mining
//
//  Tier 2 — Episodes   (max_episodes.json)
//      QA pairs — rolling buffer, semantic search retrieval (top-k)
//      Auto-summarised into Tier 3 when count > 50
//
//  Tier 3 — Summaries  (max_summaries.json)
//      AI-compressed episode history — always in prompt (≤3 chapters)
//      Keeps Max's long-term recall without ballooning token usage
//
//  Retrospective mining
//      Every 10 new episodes, a background pass scans unreviewed QA pairs
//      and extracts facts/preferences that the per-turn extractor may have missed.
//      Prevents the "mother's name only in episodes" failure mode where a fact
//      shared in one language isn't retrieved in a different-language query.

final class MemoryStore {
    static let shared = MemoryStore()

    // MARK: - Configuration

    private let maxFactsInPrompt              = 25
    private let maxSummariesKept              = 5
    private let maxSummariesInPrompt          = 3
    // Word-count based summarization: smarter than episode count because a few
    // long conversations matter more than 50 one-liners.
    private let episodeWordCountThreshold     = 1_000  // ~1 000 words → compress
    private let episodeCountThreshold         = 12     // also summarize after enough turns
    private let episodesToSummarizeCount      = 40     // how many to compress per pass
    private let maxEpisodesHardCap            = 200    // absolute ceiling before forced trim
    private let minSimilarity: Double         = 0.25
    private let miningBatchSize               = 15   // episodes per retrospective mining pass
    private let miningTriggerThreshold        = 10   // new episodes before mining runs

    // MARK: - State

    private var facts:    [Memory]        = []
    private var episodes: [Memory]        = []
    private var summaries:[MemorySummary] = []

    private let serialQueue = DispatchQueue(label: "com.max.memorystore", qos: .utility)
    private let nlEmbedding: NLEmbedding?

    // MARK: - Init

    private init() {
        nlEmbedding = NLEmbedding.sentenceEmbedding(for: .english)
        if nlEmbedding != nil { print("[MemoryStore] NLEmbedding ready ✅") }
        else { print("[MemoryStore] NLEmbedding unavailable — recency fallback only ⚠️") }
        load()
    }

    // MARK: - Public write API

    /// Routes by tag: "fact" → facts store (deduplicating), anything else → episodes store.
    func add(text: String, tags: [String] = []) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let vec = embeddingOnMainThread(for: text)
        let memory = Memory(text: text, embedding: vec, tags: tags)

        serialQueue.async { [weak self] in
            guard let self else { return }
            if tags.contains("fact") {
                self.deduplicateAndAddFact(memory)
                self.saveFacts()
            } else {
                self.episodes.append(memory)
                if self.episodes.count > self.maxEpisodesHardCap {
                    self.episodes = Array(self.episodes.suffix(self.maxEpisodesHardCap / 2))
                }
                self.saveEpisodes()
            }
            print("[MemoryStore] +1 (\(self.facts.count)f/\(self.episodes.count)e/\(self.summaries.count)s): \(text.prefix(60))")
        }
    }

    // MARK: - Summarisation support (called by AgentBrain)

    // MARK: - Retrospective episode mining

    /// Timestamp of the last mining pass (persisted across launches).
    private var lastMiningDate: Date {
        get {
            let t = UserDefaults.standard.double(forKey: "maxMemoryLastMining_v1")
            return t > 0 ? Date(timeIntervalSince1970: t) : .distantPast
        }
        set { UserDefaults.standard.set(newValue.timeIntervalSince1970, forKey: "maxMemoryLastMining_v1") }
    }

    /// Episodes added after the last mining pass (not yet scanned for facts).
    var unmindedEpisodes: [Memory] {
        let cutoff = lastMiningDate
        return serialQueue.sync { episodes.filter { $0.timestamp > cutoff } }
    }

    /// True when enough new episodes have accumulated to warrant a mining pass.
    var needsEpisodeMining: Bool {
        let cutoff = lastMiningDate
        return serialQueue.sync {
            episodes.filter { $0.timestamp > cutoff }.count >= miningTriggerThreshold
        }
    }

    /// Called after a successful mining pass so the next pass only covers new episodes.
    func recordMiningCompleted() {
        lastMiningDate = Date()
        print("[MemoryStore] Mining timestamp updated")
    }

    // MARK: - Fact consolidation (AI-powered deduplication)

    /// True when enough facts have accumulated that an AI deduplication pass is worthwhile.
    var needsFactConsolidation: Bool {
        serialQueue.sync { facts.count > 12 }
    }

    /// Convenience overload that resolves the AI service from ServiceFactory.
    /// Preserves call-sites (e.g. ContentView Settings button) that don't have a
    /// direct service reference. Prefer `consolidateFacts(using:)` in new code.
    func consolidateFacts() async {
        await consolidateFacts(using: ServiceFactory.makeAIService())
    }

    /// Runs an AI consolidation pass over the stored facts using the provided service.
    ///
    /// Accepts an `AIServiceProtocol` so that both the OSS (LocalAIService) and Paid
    /// (ProxyAIService) targets use the correct backend — matching whichever service
    /// AgentBrain was initialised with.
    ///
    /// Inspired by the OpenAI context-personalisation cookbook Step 8:
    /// session notes → consolidate → global memory.
    /// Here we consolidate the fact store itself — removing duplicates and merging
    /// near-duplicate entries without losing any genuine distinct information.
    func consolidateFacts(using aiService: any AIServiceProtocol) async {
        let snapshot = serialQueue.sync { facts }
        guard snapshot.count > 1 else { return }
        print("[MemoryStore] Consolidating \(snapshot.count) facts…")

        let cleanedTexts = await aiService.consolidateFacts(snapshot)

        // Compute embeddings outside the serialQueue (requires main-thread access)
        var newFacts: [Memory] = []
        for text in cleanedTexts {
            let vec = embeddingOnMainThread(for: text)
            newFacts.append(Memory(text: text, embedding: vec, tags: ["fact"]))
        }

        serialQueue.async { [weak self] in
            guard let self else { return }
            let before = self.facts.count
            self.facts = newFacts
            self.saveFacts()
            print("[MemoryStore] Consolidated \(before) → \(newFacts.count) facts ✅")
        }
    }

    /// True when accumulated episode text exceeds the word-count threshold.
    /// Word-count is a better proxy for "too much context" than raw episode count
    /// because a few long conversations cost more tokens than many short ones.
    var needsSummarization: Bool {
        serialQueue.sync {
            let words = episodes.reduce(0) { acc, ep in
                acc + ep.text.split(separator: " ").count
            }
            return words > episodeWordCountThreshold || episodes.count >= episodeCountThreshold
        }
    }

    /// Returns the oldest N episodes for the summarisation model to compress.
    func oldestEpisodesForSummary() -> [Memory] {
        serialQueue.sync { Array(episodes.prefix(episodesToSummarizeCount)) }
    }

    /// Called after a summary has been generated — removes the now-compressed episodes
    /// and stores the summary chapter.
    func commitSummary(text: String, replacingFirstN count: Int) {
        serialQueue.async { [weak self] in
            guard let self, self.episodes.count >= count else { return }
            self.episodes = Array(self.episodes.dropFirst(count))
            let s = MemorySummary(text: text, episodeCount: count)
            self.summaries.append(s)
            if self.summaries.count > self.maxSummariesKept {
                self.summaries = Array(self.summaries.suffix(self.maxSummariesKept))
            }
            self.saveEpisodes()
            self.saveSummaries()
            print("[MemoryStore] Committed summary covering \(count) episodes ✅")
        }
    }

    // MARK: - Context retrieval (primary read API)

    /// Returns all three tiers of memory ready for the system prompt.
    /// Always includes all facts + summaries; episodes are semantically ranked.
    func context(for query: String, topK: Int = 4) -> MemoryContext {
        let queryVec = embeddingOnMainThread(for: query)

        return serialQueue.sync {
            // Tier 1: all facts (most recent up to cap)
            let f = Array(facts.suffix(maxFactsInPrompt))

            // Tier 2: semantic search over episodes, always augmented with the most
            // recent 2 episodes for cross-lingual robustness (a Hebrew query asking
            // about something last discussed in English may not score above minSimilarity,
            // but the most recent exchange almost always contains the right context).
            let recentEps = Array(episodes.suffix(2))
            var eps: [Memory] = []
            if !queryVec.isEmpty {
                let ranked = episodes
                    .compactMap { m -> (Memory, Double)? in
                        guard m.embedding.count == queryVec.count else { return nil }
                        let sim = cosineSimilarity(queryVec, m.embedding)
                        return sim >= minSimilarity ? (m, sim) : nil
                    }
                    .sorted { $0.1 > $1.1 }
                    .prefix(topK)
                    .map(\.0)
                // Merge semantic results with the most-recent episodes (dedup by id)
                var seen = Set(ranked.map(\.id))
                eps = ranked
                for r in recentEps where !seen.contains(r.id) {
                    eps.append(r)
                    seen.insert(r.id)
                }
            }
            if eps.isEmpty { eps = recentEps }

            // Tier 3: most recent summaries (up to cap)
            let sums = Array(summaries.suffix(maxSummariesInPrompt))

            print("[MemoryStore] Context: \(f.count)f + \(eps.count)e + \(sums.count)s for '\(query.prefix(30))'")
            return MemoryContext(facts: f, episodes: eps, summaries: sums)
        }
    }

    // MARK: - UI helpers

    /// All stored memories combined (for the Memories view).
    var all: [Memory] { serialQueue.sync { facts + episodes } }

    /// Total stored item count.
    var count: Int { serialQueue.sync { facts.count + episodes.count + summaries.count } }

    /// All summary chapters (for the Memories view).
    var allSummaries: [MemorySummary] { serialQueue.sync { summaries } }

    func delete(id: UUID) {
        serialQueue.async { [weak self] in
            guard let self else { return }
            let wasFact = self.facts.contains { $0.id == id }
            self.facts.removeAll { $0.id == id }
            self.episodes.removeAll { $0.id == id }
            if wasFact { self.saveFacts() } else { self.saveEpisodes() }
        }
    }

    func clear() {
        serialQueue.async { [weak self] in
            guard let self else { return }
            self.facts = []; self.episodes = []; self.summaries = []
            self.saveFacts(); self.saveEpisodes(); self.saveSummaries()
            print("[MemoryStore] Cleared all tiers")
        }
    }

    // MARK: - Fact deduplication
    //
    // Strategy (in priority order):
    //
    // 1. Embedding similarity ≥ 0.85 → same-topic fact → replace
    //    "User's wife is Chen" vs "User's wife's name is Chen" → ~0.92 → replace ✓
    //    "User's name is X"    vs "User's father's name is Y" → ~0.55 → keep both ✓
    //
    // 2. Keyword match (2+ meaningful keywords shared) when embeddings are unavailable.
    //    Stop words stripped: "user", "is", "name", "named", "called", "the", etc.
    //    Relationship nouns kept: "father", "wife", "dog", "mother", "brother", etc.

    private static let factStopWords: Set<String> = [
        "user", "users", "is", "are", "was", "were", "be", "been",
        "the", "a", "an", "of", "in", "at", "to", "and", "or",
        "that", "this", "it", "he", "she", "they", "their", "name",
        "named", "called", "known", "like", "likes", "has", "have",
        "had", "his", "her", "my", "your", "our", "its"
    ]

    private func deduplicateAndAddFact(_ memory: Memory) {
        // ── Primary: embedding-based similarity ────────────────────────────────
        if !memory.embedding.isEmpty {
            if let idx = facts.firstIndex(where: { m in
                guard !m.embedding.isEmpty, m.embedding.count == memory.embedding.count else { return false }
                return cosineSimilarity(m.embedding, memory.embedding) >= 0.85
            }) {
                let old = facts[idx].text
                facts[idx] = memory
                print("[MemoryStore] Updated fact (embedding): \"\(old.prefix(40))\" → \"\(memory.text.prefix(40))\"")
                return
            }
        }

        // ── Fallback: keyword overlap (meaningful nouns only, stop words removed) ──
        let newKW = meaningfulKeywords(from: memory.text)
        if !newKW.isEmpty,
           let idx = facts.firstIndex(where: { m in
               let existing = meaningfulKeywords(from: m.text)
               return !existing.isEmpty && newKW.intersection(existing).count >= 2
           }) {
            let old = facts[idx].text
            facts[idx] = memory
            print("[MemoryStore] Updated fact (keywords): \"\(old.prefix(40))\" → \"\(memory.text.prefix(40))\"")
        } else {
            facts.append(memory)
            print("[MemoryStore] New fact (\(facts.count)): \(memory.text.prefix(60))")
        }
    }

    private func meaningfulKeywords(from text: String) -> Set<String> {
        Set(
            text.lowercased()
                .components(separatedBy: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
                .filter { !$0.isEmpty && $0.count > 2 && !Self.factStopWords.contains($0) }
        )
    }

    // MARK: - Persistence

    private var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    private var factsURL:    URL { documentsURL.appendingPathComponent("max_facts.json") }
    private var episodesURL: URL { documentsURL.appendingPathComponent("max_episodes.json") }
    private var summariesURL:URL { documentsURL.appendingPathComponent("max_summaries.json") }
    private var legacyURL:   URL { documentsURL.appendingPathComponent("max_memories.json") }

    private func load() {
        // One-time migration from the old single-file format
        if let data = try? Data(contentsOf: legacyURL),
           let old  = try? JSONDecoder().decode([Memory].self, from: data) {
            let mf = old.filter { $0.tags.contains("fact") }
            let me = old.filter { !$0.tags.contains("fact") }
            serialQueue.async { [weak self] in
                guard let self else { return }
                self.facts    = mf
                self.episodes = me
                self.saveFacts(); self.saveEpisodes()
                try? FileManager.default.removeItem(at: self.legacyURL)
                print("[MemoryStore] Migrated legacy: \(mf.count)f + \(me.count)e ✅")
            }
            return
        }

        // Normal load from separate files (synchronous reads on calling thread)
        let f = (try? JSONDecoder().decode([Memory].self,        from: Data(contentsOf: factsURL)))    ?? []
        let e = (try? JSONDecoder().decode([Memory].self,        from: Data(contentsOf: episodesURL))) ?? []
        let s = (try? JSONDecoder().decode([MemorySummary].self, from: Data(contentsOf: summariesURL))) ?? []

        serialQueue.async { [weak self] in
            guard let self else { return }
            self.facts     = f
            self.episodes  = e
            self.summaries = s
            print("[MemoryStore] Loaded \(f.count)f + \(e.count)e + \(s.count)s ✅")
        }
    }

    private func saveFacts()    { save(facts,    to: factsURL) }
    private func saveEpisodes() { save(episodes, to: episodesURL) }
    private func saveSummaries(){ save(summaries,to: summariesURL) }

    private func save<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Embedding helper

    /// Always executes on the main thread to avoid NLEmbedding's silent nil returns
    /// from Swift concurrency background contexts.
    private func embeddingOnMainThread(for text: String) -> [Double] {
        guard let embedding = nlEmbedding else { return [] }
        if Thread.isMainThread { return embedding.vector(for: text) ?? [] }
        return DispatchQueue.main.sync { embedding.vector(for: text) ?? [] }
    }

    // MARK: - Cosine similarity

    private func cosineSimilarity(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, magA = 0.0, magB = 0.0
        for i in 0..<a.count {
            dot  += a[i] * b[i]
            magA += a[i] * a[i]
            magB += b[i] * b[i]
        }
        let denom = magA.squareRoot() * magB.squareRoot()
        return denom > 0 ? dot / denom : 0
    }
}
