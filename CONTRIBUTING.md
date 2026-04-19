# Contributing Guide

This document describes the coding patterns, conventions, and architectural rules used throughout the Max AI Assistant codebase. All contributions should match these patterns so the codebase remains consistent.

---

## Table of Contents

- [Project Conventions at a Glance](#project-conventions-at-a-glance)
- [Concurrency Model](#concurrency-model)
- [Service Layer Pattern](#service-layer-pattern)
- [Memory Architecture Rules](#memory-architecture-rules)
- [SwiftUI Patterns](#swiftui-patterns)
- [Naming Conventions](#naming-conventions)
- [Error Handling](#error-handling)
- [Logging](#logging)
- [Persistence](#persistence)
- [API Calls](#api-calls)
- [Adding a New Capability](#adding-a-new-capability)
- [What Not to Do](#what-not-to-do)

---

## Project Conventions at a Glance

| Rule | Detail |
|---|---|
| Swift version | 5.0 |
| Deployment target | iOS 26.2 |
| Default actor isolation | `@MainActor` (project-wide build setting) |
| Concurrency style | Swift structured concurrency — `async/await`, `Task`, `Task.detached` |
| UI framework | SwiftUI primary; UIKit for image handling (`UIImage`, `UIImageView`) |
| Singletons | Static `shared` + `private init()` for all services |
| External dependencies | Swift Package Manager only; no CocoaPods, no Carthage |
| Secrets | Never hardcoded — always read from `UserDefaults` / `@AppStorage` at runtime |
| Comments | Explain *why*, never *what*; use `// MARK: -` sections in every file |

---

## Concurrency Model

### Default actor isolation

The project sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. This means **every type is implicitly `@MainActor`** unless you explicitly opt out. This is intentional — all UI state mutations happen on the main thread without extra annotation.

```swift
// All instance methods run on the main actor by default
final class MyNewService: ObservableObject {
    @Published var result: String = ""

    func doWork() async {
        // Already on MainActor — fine for UI updates
    }
}
```

### Background work — use `Task.detached` with explicit priority

For CPU-intensive or I/O-bound operations that must not block the UI, use `Task.detached`:

```swift
Task.detached(priority: .background) {
    // nonisolated context — no implicit MainActor
    await SomeService.expensiveOperation()
}
```

All background methods in `AgentBrain` are marked `nonisolated static` so they can safely be called from `Task.detached`:

```swift
private nonisolated static func storeMemories(query: String, answer: String, vision: Bool) {
    // nonisolated — can run on any thread
}
```

### Thread-safe shared state — use a serial DispatchQueue

`MemoryStore` protects its mutable arrays with:

```swift
private let serialQueue = DispatchQueue(label: "com.max.memorystore", qos: .utility)
```

- **Reads** that need to return a value use `serialQueue.sync { … }`.
- **Writes** use `serialQueue.async { … }`.
- **Never** call `serialQueue.sync` from the main thread in a write path — that risks deadlock if the queue is busy.

### NLEmbedding must run on the main thread

`NLEmbedding.vector(for:)` silently returns `nil` from Swift concurrency background contexts. Always use the established helper:

```swift
private func embeddingOnMainThread(for text: String) -> [Double] {
    guard let embedding = nlEmbedding else { return [] }
    if Thread.isMainThread { return embedding.vector(for: text) ?? [] }
    return DispatchQueue.main.sync { embedding.vector(for: text) ?? [] }
}
```

### Parallel async tasks — use `async let`

When two operations are independent, run them in parallel with `async let`. This pattern is already used in `AgentBrain.respond` and should be followed for any new parallel work:

```swift
async let resultA = serviceA.fetch()
async let resultB = serviceB.fetch()
let (a, b) = await (resultA, resultB)
```

---

## Service Layer Pattern

All services follow the same shape:

```swift
final class MyService {
    static let shared = MyService()
    private init() {}

    func doSomething() async -> ResultType {
        // …
    }
}
```

- **Singleton via `static let shared`** — never instantiate services directly in views.
- **`private init()`** — prevents accidental extra instances.
- **No `ObservableObject`** on pure services — only view models and stores that publish UI-relevant state conform to `ObservableObject`.
- **`@MainActor`** on `VisualMemoryStore` because it publishes `@Published var memories` consumed directly by SwiftUI.
- **No `@MainActor`** on `OpenAIService` or `SerperService` — they are stateless HTTP clients and can be called from any context.

---

## Memory Architecture Rules

The three-tier memory system has strict routing:

| Tag | Destination | File |
|---|---|---|
| `["fact"]` | `facts` array — deduplicating write | `max_facts.json` |
| anything else | `episodes` array | `max_episodes.json` |

**Always route through `MemoryStore.shared.add(text:tags:)`** — never write to the files directly.

```swift
// Correct — routes to facts tier with deduplication
MemoryStore.shared.add(text: "User's wife is named Chen", tags: ["fact"])

// Correct — routes to episodes tier
MemoryStore.shared.add(text: "User asked: … Max answered: …", tags: ["qa"])
```

**Never add facts from the main turn** without an async background `Task`. Memory writes are dispatched on a serial utility queue — they must not block `AgentBrain.respond`.

---

## SwiftUI Patterns

### `@StateObject` vs `@ObservedObject`

- Use `@StateObject` when the view **owns** the lifecycle of an observable.
- Use `@ObservedObject` for singletons passed in from outside.
- Use `@EnvironmentObject` only when the object needs to propagate deeply without explicit passing.

### Subviews and decomposition

`ContentView.swift` is large (~1 700 lines). New UI components should be added as **dedicated `View` structs** at the bottom of the file or in a new file if they exceed ~100 lines. Name them descriptively: `ChatBubbleView`, `MemoriesView`, `DebugInfoSheet`.

### `@MainActor` on view models

Any `ObservableObject` that publishes state consumed by SwiftUI should be `@MainActor` (or confirm all `@Published` mutations happen on the main thread):

```swift
@MainActor
final class MyViewModel: ObservableObject {
    @Published var items: [String] = []
}
```

---

## Naming Conventions

Follow the patterns already established:

| Element | Convention | Example |
|---|---|---|
| Types | `UpperCamelCase` | `AgentBrain`, `VisualMemoryStore` |
| Properties / variables | `lowerCamelCase` | `chatHistory`, `isThinking` |
| Private properties | `lowerCamelCase` (no underscore prefix) | `shortTerm`, `nlEmbedding` |
| Constants | `lowerCamelCase` (private `let`) | `shortTermLimit`, `minSimilarity` |
| Static constants | `lowerCamelCase` | `corePersonality`, `jsonOutputInstruction` |
| File names | Match the primary type name | `AgentBrain.swift`, `MemoryStore.swift` |
| `MARK` sections | `// MARK: - Section Name` | `// MARK: - Memory storage` |

**Prefix console logs with the class name in brackets:**

```swift
print("[MyService] Description of event")
```

---

## Error Handling

### Service errors — typed `enum` conforming to `LocalizedError`

Follow `OpenAIService.ServiceError`:

```swift
enum ServiceError: LocalizedError {
    case missingAPIKey, httpError(Int), decodingFailed

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:    return "Add your API key in Settings."
        case .httpError(let c): return "HTTP error \(c) — please try again."
        case .decodingFailed:   return "Could not decode the response."
        }
    }
}
```

### Background tasks — silent failures are acceptable

Background memory tasks (`Task.detached(priority: .background)`) should not surface errors to the user. Use `try?` or `guard … else { return }` patterns:

```swift
let result = (try? await someService.call()) ?? fallbackValue
```

### User-facing errors — `@Published` error state on the view model

When an error must be shown to the user, publish it on `AgentBrain` or `ContentView`'s state and present it with `.alert` or an inline error message. Never call `fatalError` in production paths.

---

## Logging

All console output must use the established prefix format:

```swift
print("[MyService] Loaded \(items.count) items ✅")
print("[MyService] Failed to decode: \(error.localizedDescription)")
```

- Use `✅` for successful background operations.
- Use `⚠️` for non-fatal warnings (e.g. fallback modes).
- Never use `NSLog` — `print` is sufficient and carries less overhead.
- Never log API keys, user message content in full, or base64 image data.

---

## Persistence

All persistence uses `JSONEncoder` / `JSONDecoder` with **atomic writes** to the Documents directory:

```swift
private func save<T: Encodable>(_ value: T, to url: URL) {
    guard let data = try? JSONEncoder().encode(value) else { return }
    try? data.write(to: url, options: .atomic)
}
```

- Always use `.atomic` to prevent partial writes on crash.
- Always use `try?` for persistence writes — data loss is preferable to a crash.
- New persistent stores should follow the path pattern: `Documents/<prefix>_<name>.json`.
- When adding a new field to a `Decodable` model that must remain backward compatible with existing JSON, use `try? c.decode(…)` (optional decode) — see `VisualMemory`'s custom `init(from:)` for the established pattern.

### UserDefaults keys

Use a versioned suffix (`_v2`, `_v3`) if you change the schema of an existing key to avoid reading stale data after an app update. The migration pattern from `AgentBrain`:

```swift
let oldKey = "max_agent_preferences"
if let old = UserDefaults.standard.dictionary(forKey: oldKey) as? [String: String], !old.isEmpty {
    // migrate
    UserDefaults.standard.set(migrated, forKey: newKey)
    UserDefaults.standard.removeObject(forKey: oldKey)
}
```

---

## API Calls

### All HTTP calls go through the single `postFull(body:)` method in `OpenAIService`

Do not create additional `URLSession` instances or bypass `postFull`. New OpenAI call types should be added as methods on `OpenAIService` that ultimately call `post(body:)` or `postFull(body:)`.

### Model and token budget

Current defaults used across all calls:

| Call type | `max_tokens` | `temperature` |
|---|---|---|
| Main chat | 250 | default |
| Intent classification | 5 | 0 |
| Fact extraction | 120 | 0 |
| Episode mining | 500 | 0 |
| Fact consolidation | 500 | 0 |
| Episode summarisation | 200 | 0 |
| Visual memory analysis | 500 | 0 |
| Country code extraction | 5 | 0 |

Keep deterministic utility calls (classification, extraction, consolidation) at `temperature: 0`. Creative / conversational calls can use the model default.

### Image encoding

Images sent to OpenAI are JPEG-encoded at reduced quality to minimise payload size:
- Main vision queries: `compressionQuality: 0.6`, `detail: "low"`
- Visual memory analysis: `compressionQuality: 0.65`, `detail: "high"` (needs detail for object inventory)
- Image-to-search-query: `compressionQuality: 0.5`, `detail: "low"`

Do not use `detail: "high"` for anything except visual memory saves — it is significantly more expensive.

---

## Adding a New Capability

Follow these steps when adding a new end-to-end feature:

1. **Define the intent** — if the new capability requires a new message intent (beyond `chat`, `search`, `news`, `vision`), add it to `OpenAIService.MessageIntent` and update the `classifyIntent` prompt.

2. **Add the service method** — add a new `async` method to the appropriate service class (`OpenAIService`, `SerperService`, or a new service file).

3. **Route in `AgentBrain.respond`** — gate the new capability behind the classified intent. Follow the existing pattern:
   ```swift
   let wantsNewFeature = intent == .newIntent
   if wantsNewFeature {
       // call the new service
   }
   ```

4. **Inject context** — if the new capability produces context that should be included in the system prompt, inject it as a system message in `buildMessages`, modelled on how search results and visual memory context are currently injected.

5. **Update `MaxSoul`** — if the capability changes what Max "knows" or "can do", update `corePersonality` or add a new section to `buildSystemPrompt`.

6. **Persist if needed** — if the capability stores data, add a new JSON file under Documents following the established persistence pattern.

---

## What Not to Do

- **Do not hardcode API keys, client tokens, or secrets** in source files or `.xcconfig` files. All secrets are user-supplied at runtime via `@AppStorage`.
- **Do not use `DispatchQueue.main.sync` from the main thread** — this will deadlock.
- **Do not use `@State` for data that must survive view re-creation** — use `@StateObject` or `@AppStorage`.
- **Do not add `@State` properties to `AgentBrain`** — it is not a SwiftUI view and must remain a pure `ObservableObject`.
- **Do not create multiple `NLEmbedding` instances** — `MemoryStore.shared` holds the single instance; calling `NLEmbedding.sentenceEmbedding(for:)` is expensive.
- **Do not add third-party dependencies without discussion** — the project deliberately has only one external package (the Meta SDK). Consider Apple frameworks first.
- **Do not use `print` to communicate with the user** — `print` is for developer console logs only. User-facing messages go through `@Published` state and SwiftUI views.
- **Do not use `detail: "high"` for real-time vision queries** — it increases latency and cost significantly; reserve for memory-save operations where quality matters.
- **Do not skip the `options: .atomic` flag** on file writes — partial writes corrupt the JSON and silently wipe all memory on next launch.
