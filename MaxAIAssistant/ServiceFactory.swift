import Foundation

// MARK: - ServiceFactory
//
// Returns the correct AI and search service implementations for the active build target.
//
// ─────────────────────────────────────────────────────────────────────────────────
// HOW TO CONFIGURE TWO TARGETS IN XCODE
// ─────────────────────────────────────────────────────────────────────────────────
//
// Step 1 — Duplicate the existing target
//   Xcode project navigator → MaxAIAssistant target → right-click → Duplicate
//   Rename the copy to "MaxAIAssistant Pro" (or "MaxAIAssistant Paid").
//
// Step 2 — Add the PROXY_TARGET compiler flag to the Pro target only
//   Select the "MaxAIAssistant Pro" target → Build Settings tab
//   Search "Active Compilation Conditions"
//   Under both Debug and Release, add:   PROXY_TARGET
//
//   (The OSS target intentionally has no PROXY_TARGET flag — the #else branch runs.)
//
// Step 3 — At app startup (MaxAIAssistantApp.init), configure the proxy credentials
//   After a successful in-app purchase receipt validation on your server:
//
//       KeychainHelper.write(key: KeychainHelper.proxyBearerKeyName, value: token)
//       KeychainHelper.write(key: KeychainHelper.proxyURLKeyName,    value: "https://api.maxai.studio/v1")
//
// Step 4 — AgentBrain uses ServiceFactory automatically via its default parameter values.
//   No changes are needed in AgentBrain or ContentView when switching targets.
//
// ─────────────────────────────────────────────────────────────────────────────────

enum ServiceFactory {

    // MARK: - AI service

    /// Returns the AI backend for the active build target.
    ///
    /// OSS target    → LocalAIService (= OpenAIService)
    ///                 Calls OpenAI directly. Credentials from Keychain / UserDefaults.
    ///
    /// Paid target   → ProxyAIService
    ///                 Routes through your secure proxy. Authenticated via bearer token.
    static func makeAIService() -> any AIServiceProtocol {
        #if PROXY_TARGET
        return ProxyAIService.proxyShared
        #else
        return LocalAIService.shared
        #endif
    }

    // MARK: - Search service

    /// Returns the web/news search backend.
    ///
    /// Currently the same SerperService singleton is used for both targets.
    /// Replace with a ProxySearchService in the future to avoid exposing
    /// the Serper key on-device for the Paid target.
    static func makeSearchService() -> any SearchServiceProtocol {
        return SerperService.shared
    }
}
