import Foundation
import UIKit

// MARK: - Serper result models

struct SerperResult: Identifiable, Codable {
    let id        = UUID()
    let title:    String
    let link:     String
    let snippet:  String?
    // Both search and news responses use "imageUrl" at top level or nested "attributes"
    let imageUrl: String?
    // Present in news results
    let source:   String?
    let date:     String?
    // Present in organic results
    let displayLink: String?

    /// Best available display source (domain or source name)
    var sourceName: String {
        source ?? displayLink ?? (URL(string: link)?.host ?? link)
    }

    enum CodingKeys: String, CodingKey {
        case title, link, snippet, imageUrl, source, date, displayLink
    }

    // id is generated locally — exclude from Codable
}

struct SerperResponse: Decodable {
    let organic:  [SerperResult]?   // /search endpoint
    let news:     [SerperResult]?   // /news endpoint

    /// Unified list regardless of endpoint
    var results: [SerperResult] { (organic ?? []) + (news ?? []) }
}

// MARK: - SerperService

/// Thin wrapper around the Serper.dev Google Search API.
/// API key is stored in UserDefaults (AppStorage) — move to server before release.
final class SerperService {

    static let shared = SerperService()
    private init() {}

    // MARK: - Country code resolution
    //
    // Priority order:
    //  1. Stored facts (most reliable — user told Max where they live)
    //  2. Raw query text (e.g. "news from Berlin" → de)
    //  3. Default "us"
    //
    // The static table is shared between both checks so new entries only need adding once.

    private static let locationMap: [(String, String)] = [
        // Israel
        ("israel", "il"), ("ramat gan", "il"), ("tel aviv", "il"),
        ("jerusalem", "il"), ("haifa", "il"), ("ישראל", "il"),
        ("רמת גן", "il"), ("תל אביב", "il"),
        // USA
        ("united states", "us"), ("usa", "us"), ("new york", "us"),
        ("los angeles", "us"), ("chicago", "us"), ("california", "us"),
        ("texas", "us"), ("florida", "us"),
        // UK
        ("united kingdom", "uk"), ("england", "uk"), ("london", "uk"),
        ("manchester", "uk"),
        // Germany
        ("germany", "de"), ("berlin", "de"), ("munich", "de"),
        // France
        ("france", "fr"), ("paris", "fr"),
        // Canada
        ("canada", "ca"), ("toronto", "ca"), ("vancouver", "ca"),
        // Australia
        ("australia", "au"), ("sydney", "au"), ("melbourne", "au"),
        // India
        ("india", "in"), ("mumbai", "in"), ("delhi", "in"),
        // Brazil
        ("brazil", "br"), ("são paulo", "br"),
        // Netherlands
        ("netherlands", "nl"), ("amsterdam", "nl"),
        // Spain
        ("spain", "es"), ("madrid", "es"), ("barcelona", "es"),
        // Italy
        ("italy", "it"), ("rome", "it"), ("milan", "it"),
        // Japan
        ("japan", "jp"), ("tokyo", "jp"), ("osaka", "jp"),
        // Mexico
        ("mexico", "mx"), ("mexico city", "mx"),
        // Argentina
        ("argentina", "ar"), ("buenos aires", "ar"),
        // Portugal
        ("portugal", "pt"), ("lisbon", "pt"),
        // Sweden
        ("sweden", "se"), ("stockholm", "se"),
        // Poland
        ("poland", "pl"), ("warsaw", "pl"),
    ]

    /// Returns true when at least one location entry is found in the user's stored facts.
    static func hasKnownLocation(from facts: [Memory]) -> Bool {
        let combined = facts.map(\.text).joined(separator: " ").lowercased()
        return locationMap.contains { (keyword, _) in combined.contains(keyword) }
    }

    /// Resolve country code from stored facts, then query text, then default.
    static func countryCode(from facts: [Memory], queryHint: String = "") -> String {
        let combined = (facts.map(\.text) + [queryHint]).joined(separator: " ").lowercased()
        for (keyword, code) in locationMap where combined.contains(keyword) {
            return code
        }
        return "us"
    }

    // MARK: - Search

    /// Performs a web search or news search using Serper.dev.
    /// - Parameters:
    ///   - query: Search query string
    ///   - isNews: Use the /news endpoint instead of /search
    ///   - gl: Country code (e.g. "il", "us")
    ///   - num: Max results (default 6)
    func search(
        query: String,
        isNews: Bool = false,
        gl: String = "us",
        num: Int = 6
    ) async -> [SerperResult] {
        let apiKey = UserDefaults.standard.string(forKey: "serper_api_key") ?? ""
        guard !apiKey.isEmpty else {
            print("[Serper] No API key — add one in Settings")
            return []
        }

        let endpoint = isNews
            ? "https://google.serper.dev/news"
            : "https://google.serper.dev/search"

        guard let url = URL(string: endpoint) else { return [] }

        var body: [String: Any] = ["q": query, "num": num, "gl": gl]
        if isNews { body["tbs"] = "qdr:d" }  // news from last day

        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return [] }

        var req = URLRequest(url: url)
        req.httpMethod  = "POST"
        req.httpBody    = bodyData
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "X-API-KEY")

        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            let decoded   = try JSONDecoder().decode(SerperResponse.self, from: data)
            print("[Serper] Got \(decoded.results.count) results for '\(query.prefix(40))'")
            return Array(decoded.results.prefix(num))
        } catch {
            print("[Serper] Error: \(error.localizedDescription)")
            return []
        }
    }
}

// MARK: - SearchServiceProtocol conformance
//
// SerperService already implements `search(query:isNews:gl:num:)` with the exact
// signature required by SearchServiceProtocol — this declaration is the only addition.

extension SerperService: SearchServiceProtocol {}

// MARK: - Async thumbnail loader

/// In-memory image cache keyed by URL string.
/// `@MainActor` ensures cache reads/writes are always on the main thread.
/// Not an ObservableObject — used as a shared utility, not a SwiftUI binding.
@MainActor
final class ThumbnailCache {

    static let shared = ThumbnailCache()
    private init() {}

    private var cache: [String: UIImage] = [:]

    func load(urlString: String) async -> UIImage? {
        if let cached = cache[urlString] { return cached }
        guard let url = URL(string: urlString) else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let img = UIImage(data: data) else { return nil }
        cache[urlString] = img
        return img
    }
}
