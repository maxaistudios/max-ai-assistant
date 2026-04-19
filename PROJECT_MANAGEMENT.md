# Project Management Overview

## Current Development State

### What Is Fully Implemented

The following components are production-quality and actively working:

| Component | Status | Notes |
|---|---|---|
| **Ray-Ban Meta glasses integration** | Working | MWDATCore/MWDATCamera v0.5.0; OAuth via Meta View app; live video stream + photo capture |
| **AI orchestration** (`AgentBrain`) | Working | Intent classification, parallel memory retrieval, context building, JSON response parsing |
| **Three-tier memory system** | Working | Facts/Episodes/Summaries with NLEmbedding semantic search, background mining, summarisation, and fact consolidation |
| **Visual memory** | Working | Save photo → AI object inventory → searchable indexed gallery; "where are my keys?" style queries |
| **Wake word + voice input** | Working | "Hey Max" detection, awake-stage timeout, fresh-engine-per-session TTS race condition fix |
| **OpenAI GPT-4o-mini** | Working | Chat, vision, JSON mode, all utility agents (fact extractor, miner, summariser, consolidator, intent classifier, country extractor, image descriptor) |
| **Serper web/news search** | Working | Intent-routed, country-code resolved, image-to-query fallback, trivial-query guard |
| **Persona / system prompt** | Working | `MaxSoul` builds dynamic prompt from all memory tiers per turn |
| **Debug mode** | Working | Per-turn system prompt, token usage, raw JSON, memory tier counts |
| **Settings sheet** | Working | API key entry, speech locale, preferences |
| **Visual memories gallery** | Working | `VisualMemoriesView` — search, detail, user notes, delete |
| **Location tagging** | Working | Reverse geocoded neighbourhood+city label attached to each visual memory |
| **Camera roll integration** | Working | Add-only Photos permission; visual memories saved to Recents |
| **Preference extraction** | Working | Name, detail level, language detected from natural conversation |

---

### Known Limitations & Active Issues

| Issue | Root Cause | Workaround / Status |
|---|---|---|
| "Hey Max" detection accuracy | Simple `contains("hey max")` substring match — no fuzzy matching | Works well in quiet environments; degrades with accent or noise |
| Wake word triggers on recordings/TV | No speaker verification | User should disable listening in noisy environments |
| NLEmbedding unavailable on some locales | Language data not downloaded on non-English devices | Falls back to recency-only retrieval; no code fix needed |
| `max_tokens: 250` may truncate long answers | Conservative token budget | Increase for detailed query use cases |
| API keys in `UserDefaults` (not Keychain) | MVP choice | Should be migrated to `SecItemAdd`/Keychain before production release |
| Meta ClientToken hardcoded in `Info.plist` | Meta SDK requirement | Flag as sensitive — do not expose in public repos |
| `ContentView.swift` is ~1 700 lines | All UI in one file | Functional but needs decomposition |
| No unit tests | Not yet written | See Next Steps |

---

## Architecture Decisions (Context for Future Contributors)

### Why JSON files instead of Core Data or SQLite

The memory system was intentionally kept simple — JSON files with `JSONEncoder/Decoder` require no schema migrations and the data is inspectable for debugging. At current scale (hundreds of memories), JSON is fast enough. The `brainIdea.txt` design doc considered SQLite + GRDB for vector storage, but `NLEmbedding`'s built-in cosine search over in-memory arrays was chosen to eliminate an external dependency.

### Why `gpt-4o-mini` instead of a larger model

`gpt-4o-mini` is used for all calls because it is substantially cheaper and faster while being adequate for all current tasks (intent classification, fact extraction, conversational answers). The architecture does not prevent swapping in a larger model for main chat only — this is a future option.

### Why not Apple's Foundation Models framework

`brainIdea.txt` outlines an on-device approach using Foundation Models (Apple's 3B parameter model) + SQLite for zero-cost, offline inference. This is not yet implemented because the Foundation Models framework requires iPhone 15 Pro or later and was not yet stable at time of development. The architecture is designed to allow this as a future swap for the `OpenAIService` layer.

### Why `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`

This eliminates a large class of data-race bugs in a UI-heavy app where most state needs to be on the main thread anyway. The trade-off is that developers must be explicit about off-thread work (`Task.detached`, `nonisolated`).

---

## Obvious Next Steps

These items are directly implied by the current state of the code and design notes.

### High Priority

**1. Keychain migration for API keys**

Both `openai_api_key` and `serper_api_key` are stored in `UserDefaults`. This is readable by any process on a jailbroken device. Migrate to the iOS Keychain using `SecItemAdd` / `SecItemCopyMatching` before shipping to external users.

**2. Unit tests for `MemoryStore` and `AgentBrain`**

The memory system has enough complexity (deduplication thresholds, mining triggers, summarisation thresholds, cosine similarity) that regressions are likely without test coverage. Priority test targets:
- `MemoryStore.deduplicateAndAddFact()` — embedding and keyword paths
- `MemoryStore.context(for:)` — verify correct tiers are returned
- `AgentBrain.cleanSearchQuery()` and `isGenericSearchPhrase()` — query cleaning edge cases
- `AgentBrain.parseGPTResponse()` — valid JSON, fenced JSON, and fallback

**3. Decompose `ContentView.swift`**

At ~1 700 lines, `ContentView.swift` mixes the streaming video UI, chat interface, toolbar, settings sheet, camera controls, and multiple subview definitions. Extract into separate files:
- `ChatView.swift` — chat history + input bar
- `StreamView.swift` — glasses camera display + capture controls
- `SettingsView.swift` — settings sheet
- `ToolbarView.swift` — bottom toolbar

**4. Error surfacing to the user**

Many errors currently print to console but are never shown in the UI (e.g. Serper network failures, OpenAI 5xx errors, CoreLocation failures). Add a toast/banner notification system backed by a `@Published var errorMessage: String?` on `AgentBrain`.

### Medium Priority

**5. On-device inference via Foundation Models framework**

The `brainIdea.txt` design doc describes replacing OpenAI with Apple's on-device Foundation Models + `NLEmbedding` for zero-cost offline inference on iPhone 15 Pro and later. This would:
- Eliminate OpenAI API cost and latency for conversational turns
- Enable fully offline operation
- Require a new `FoundationModelService` replacing `OpenAIService.chat`

**6. Wake word upgrade**

Replace the `contains("hey max")` check with a dedicated keyword-spotting model (e.g. `SNClassifySoundRequest` with a trained `MLModel`, or Apple's `SoundAnalysis` framework). This would improve accuracy in noisy environments and reduce false triggers.

**7. Multi-language memory retrieval**

Currently, `NLEmbedding.sentenceEmbedding(for: .english)` is used for all embeddings. A query in Hebrew will have poor semantic similarity against memories stored in English. Options:
- Use a multilingual embedding model
- Store embeddings per-language with fallback
- Translate queries to English before embedding (using GPT micro-agent)

**8. iCloud sync for memories**

`MemoryStore` and `VisualMemoryStore` use the local Documents directory. Adding `NSUbiquitousKeyValueStore` or CloudKit sync would allow memories to persist across device replacements.

**9. Streaming responses**

`OpenAIService.chatFull()` waits for the full completion before returning. Adding server-sent events (SSE) streaming would allow the answer to appear word-by-word in the UI and enable TTS to start before the full response is received.

**10. Photo library album grouping**

Currently visual memories land in "Recents" in the Photos app. Adding them to a dedicated "Max Memories" album would require full library access (`NSPhotoLibraryUsageDescription`) instead of add-only — consider whether the privacy trade-off is worth it.

### Low Priority / Future

**11. Local SQLite / vector DB**

As the episode and facts stores grow into the thousands, the in-memory JSON + cosine loop will become a performance bottleneck. Migrate to a SQLite-backed vector store (e.g. GRDB with a virtual FTS5 table, or a dedicated vector DB) with indexed ANN search.

**12. Multiple user profiles**

The current architecture is designed for a single user. A profile selector (stored as separate `UserDefaults` domains and separate `Documents` sub-directories) would enable family sharing or multi-user households.

**13. Background session recovery**

If the app is killed mid-conversation, `AgentBrain.shortTerm` (in-memory only) is lost. Persisting the short-term conversation window to disk would allow recovery of conversational context across unexpected terminations.

---

## File Size Reference

| File | Lines | Change risk |
|---|---|---|
| `ContentView.swift` | ~1 700 | High — all primary UI |
| `OpenAIService.swift` | 575 | Medium — API surface |
| `MemoryStore.swift` | 452 | High — core data integrity |
| `VisualMemoryStore.swift` | 428 | Medium |
| `AgentBrain.swift` | 509 | High — orchestration logic |
| `SpeechManager.swift` | 321 | Medium — audio session fragility |
| `VisualMemoriesView.swift` | 353 | Low |
| `SerperService.swift` | 186 | Low |
| `MaxSoul.swift` | 143 | Medium — prompt engineering |
| `MaxAIAssistantApp.swift` | 32 | Low |

---

## Development Environment

| Requirement | Version |
|---|---|
| Xcode | 26.2 or later |
| macOS | Compatible with Xcode 26.2 |
| iOS deployment target | 26.2 |
| Swift | 5.0 |
| External packages | `meta-wearables-dat-ios` v0.5.0 |
| Physical device | iPhone (iOS 26.2+) — simulator does not support camera or MWDATCore fully |
| Glasses (optional) | Ray-Ban Meta Gen 2 or later — `MWDATMockDevice` can substitute in development |
