import UIKit
import Foundation

// MARK: - AIServiceProtocol
//
// Defines the full contract for any AI backend used by AgentBrain.
// Two concrete implementations ship with this project:
//
//   LocalAIService  (= OpenAIService)
//       OSS / Open Core target. Calls OpenAI directly.
//       Credentials read from device Keychain (primary) or UserDefaults (fallback).
//
//   ProxyAIService
//       Paid / Pro target. Routes every request through your secure proxy server.
//       Authenticated via a subscription bearer token stored in Keychain.
//
// To swap implementations at build time, configure the PROXY_TARGET compiler flag
// in the paid target's Build Settings → Swift Compiler – Custom Flags → Active
// Compilation Conditions. ServiceFactory reads that flag and returns the right instance.

protocol AIServiceProtocol: AnyObject {

    // MARK: Core chat

    /// Full multi-turn chat call. Returns text, token usage, and raw JSON for debug mode.
    func chatFull(
        messages: [[String: Any]],
        hasImage: Bool,
        image:    UIImage?,
        jsonMode: Bool
    ) async throws -> OpenAIService.ChatResult

    /// Convenience shim — returns only the text content.
    func chat(
        messages: [[String: Any]],
        hasImage: Bool,
        image:    UIImage?,
        jsonMode: Bool
    ) async throws -> String

    // MARK: Intent classification

    /// Classifies a user message into one of four routing intents.
    /// Runs in parallel with memory retrieval so it adds zero latency to the main turn.
    func classifyIntent(query: String, hasImage: Bool) async -> OpenAIService.MessageIntent

    /// Lightweight agent decision: should we auto-capture an image for this query
    /// when no image is currently attached (e.g. "what do I see?").
    func shouldAutoCaptureImage(for query: String) async -> Bool

    // MARK: Vision helpers

    /// Analyses an image being saved as a visual memory.
    /// Returns a rich description, searchable tags, and a full object inventory.
    func analyzeVisualMemory(
        image:        UIImage,
        locationName: String?,
        userFacts:    String?
    ) async -> OpenAIService.VisualMemoryAnalysis

    /// Returns a 5-8 word Google-ready description of an image (used when the user
    /// requests a web search while an image is active in the viewfinder).
    func describeImageForSearch(_ image: UIImage) async -> String

    /// Quick single-turn photo analysis without AgentBrain context.
    /// Used by direct "Ask about this" UI paths that bypass the full turn pipeline.
    func analyzePhoto(_ image: UIImage, question: String) async throws -> String

    // MARK: Memory maintenance (all run in background Tasks)

    /// Extracts personal facts from a single QA exchange immediately after each turn.
    func extractFacts(userMessage: String, assistantMessage: String) async -> [String]

    /// Retrospective mining pass — scans a batch of older episodes for personal facts
    /// that the per-turn extractor may have missed (e.g. casual mentions, other languages).
    func mineFactsFromEpisodes(_ episodes: [Memory]) async -> [String]

    /// Compresses a batch of QA episodes into a short summary paragraph for Tier 3 memory.
    func summarizeEpisodes(_ episodes: [Memory]) async -> String

    /// AI-powered deduplication pass over the stored facts array.
    /// Merges near-duplicates and resolves conflicts without losing genuine distinct facts.
    func consolidateFacts(_ facts: [Memory]) async -> [String]

    // MARK: Utility

    /// Extracts an ISO-3166-1 alpha-2 country code from free text (used for Serper `gl`).
    func extractCountryCode(from text: String) async -> String?
}

// MARK: - SearchServiceProtocol
//
// Defines the contract for any web/news search backend.
// The concrete implementation is SerperService (google.serper.dev).
// A future ProxySearchService could route queries through the same secure proxy
// to avoid exposing the Serper key on-device for the paid target.

protocol SearchServiceProtocol: AnyObject {
    /// Performs a web or news search and returns up to `num` results.
    func search(
        query:  String,
        isNews: Bool,
        gl:     String,
        num:    Int
    ) async -> [SerperResult]
}
