import UIKit
import Foundation

// MARK: - ProxyAIService
//
// The Paid / Pro target's AI service implementation.
//
// Architecture:
//   ProxyAIService subclasses OpenAIService and overrides ONLY two things:
//     1. resolvedKey   — returns the subscription bearer token instead of an OpenAI key
//     2. postFull      — sends requests to your secure proxy server instead of api.openai.com
//
//   Every single prompt, parsing routine, intent classifier, memory operation, and
//   vision helper is INHERITED from OpenAIService unchanged. This guarantees that
//   the OSS and Paid targets behave identically from the AI perspective — the only
//   difference is which backend handles the request and who is billed.
//
// Proxy server contract:
//   • Accepts POST /chat/completions with the same JSON body as OpenAI
//   • Authenticates via:  Authorization: Bearer <subscription_token>
//   • Returns the same OpenAI response format (choices[].message.content, usage, etc.)
//   • Your server validates the token against your subscription database, then forwards
//     the request to OpenAI using a server-side API key the user never sees.
//
// Configuration (set once after successful in-app purchase / subscription validation):
//   KeychainHelper.write(key: KeychainHelper.proxyBearerKeyName, value: token)
//   KeychainHelper.write(key: KeychainHelper.proxyURLKeyName,    value: "https://api.maxai.studio/v1")

final class ProxyAIService: OpenAIService {

    // MARK: - Singleton

    /// The shared proxy service instance for the Paid build target.
    /// ServiceFactory returns this when the PROXY_TARGET flag is active.
    static let proxyShared = ProxyAIService()

    // MARK: - Init

    private override init() {
        super.init()
    }

    // MARK: - Credential override
    //
    // Returns the subscription bearer token rather than an OpenAI key.
    // All guard checks in the inherited OpenAIService methods (e.g.
    // `guard !resolvedKey.isEmpty`) will now validate the bearer token instead,
    // so the service silently degrades to empty/fallback responses when the
    // subscription is not active — exactly the same UX as "no API key set".

    override var resolvedKey: String {
        KeychainHelper.read(key: KeychainHelper.proxyBearerKeyName)
            ?? UserDefaults.standard.string(forKey: "proxy_bearer_token")
            ?? ""
    }

    // MARK: - Transport override
    //
    // Replaces the OpenAI endpoint with the proxy URL.
    // The request body is identical — the proxy mirrors the OpenAI Chat Completions API.
    // Only the URL and the Authorization header change.

    override func postFull(body: [String: Any]) async throws -> ChatResult {
        let baseURL = KeychainHelper.read(key: KeychainHelper.proxyURLKeyName)
            ?? UserDefaults.standard.string(forKey: "proxy_base_url")
            ?? ""

        guard !baseURL.isEmpty else {
            throw ProxyServiceError.missingProxyURL
        }

        let token = resolvedKey
        guard !token.isEmpty else {
            throw ProxyServiceError.missingBearerToken
        }

        // Normalise the URL: ensure it ends with /chat/completions
        let urlString = baseURL
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            + "/chat/completions"

        guard let url = URL(string: urlString) else {
            throw ProxyServiceError.invalidProxyURL(urlString)
        }

        var req          = URLRequest(url: url)
        req.httpMethod   = "POST"
        req.timeoutInterval = 25
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            if let raw = String(data: data, encoding: .utf8) {
                print("[ProxyAIService] HTTP \(http.statusCode): \(raw.prefix(300))")
            }
            throw ProxyServiceError.httpError(http.statusCode)
        }

        let rawJSON = String(data: data, encoding: .utf8) ?? ""

        // The proxy returns the standard OpenAI response format, so we can reuse
        // the inherited ChatResponse decoder directly.
        guard let parsed  = try? JSONDecoder().decode(ChatResponse.self, from: data),
              let content = parsed.choices.first?.message.content else {
            throw ProxyServiceError.decodingFailed
        }

        return ChatResult(
            text:             content.trimmingCharacters(in: .whitespacesAndNewlines),
            promptTokens:     parsed.usage?.promptTokens     ?? 0,
            completionTokens: parsed.usage?.completionTokens ?? 0,
            rawJSON:          rawJSON
        )
    }

    // MARK: - Error type

    enum ProxyServiceError: LocalizedError {
        case missingProxyURL
        case invalidProxyURL(String)
        case missingBearerToken
        case httpError(Int)
        case decodingFailed

        var errorDescription: String? {
            switch self {
            case .missingProxyURL:
                return "Server URL not configured. Please contact support."
            case .invalidProxyURL(let u):
                return "Server URL is malformed (\(u)). Please contact support."
            case .missingBearerToken:
                return "Subscription token missing. Restore your purchase in Settings."
            case .httpError(401):
                return "Subscription expired or invalid — check your subscription in Settings."
            case .httpError(402):
                return "Subscription required — upgrade to Max Pro to use this feature."
            case .httpError(429):
                return "Request limit reached — please wait a moment and try again."
            case .httpError(let c):
                return "Server error \(c) — please try again or contact support."
            case .decodingFailed:
                return "Could not read the server response."
            }
        }
    }
}
