# Troubleshooting Guide

This document covers debugging steps for the specific hardware/software integrations in Max AI Assistant. Each section maps to a concrete subsystem identified in the source code.

---

## Table of Contents

- [Meta Glasses Connection (MWDATCore / MWDATCamera)](#1-meta-glasses-connection-mwdatcore--mwdatcamera)
- [Speech Recognition & Wake Word ("Hey Max")](#2-speech-recognition--wake-word-hey-max)
- [OpenAI API Errors](#3-openai-api-errors)
- [Serper Web / News Search](#4-serper-web--news-search)
- [Memory System (MemoryStore / VisualMemoryStore)](#5-memory-system-memorystore--visualmemorystore)
- [Location & Reverse Geocoding](#6-location--reverse-geocoding)
- [Photo Library Saves](#7-photo-library-saves)
- [Build & Xcode Issues](#8-build--xcode-issues)
- [General Debugging Tips](#9-general-debugging-tips)

---

## 1. Meta Glasses Connection (MWDATCore / MWDATCamera)

### Symptoms
- "Connect Glasses" does nothing or stays on a loading state
- Live video stream never starts
- App crashes on launch with a MWDATCore error

### Root causes and fixes

**SDK not configured**

`MaxAIAssistantApp.init()` calls `Wearables.configure()` inside a `do/catch`. Check the Xcode console for:
```
Failed to configure Wearables SDK: …
```
Cause: `Info.plist` is missing or has incorrect `MWDAT` keys (`ClientToken`, `MetaAppID`, `AppLinkURLScheme`, `TeamID`). Verify the plist contains exactly:
- `AppLinkURLScheme` = `maxaiassistant://`
- `MetaAppID` = your registered Meta App ID
- `ClientToken` = the token from your Meta developer portal
- `TeamID` = `$(DEVELOPMENT_TEAM)` (resolves at build time)

**OAuth redirect not returning to the app**

The Meta View app redirects back via the `maxaiassistant://` URL scheme. If the app does not reopen after OAuth:
1. Confirm `CFBundleURLSchemes` in `Info.plist` contains `maxaiassistant`.
2. Confirm `LSApplicationQueriesSchemes` contains `fb-viewapp`.
3. In `MaxAIAssistantApp`, the `onOpenURL` handler calls `Wearables.shared.handleUrl(url)` asynchronously. Add a breakpoint there to confirm the URL is received.

**Bonjour / local network blocked**

The glasses communicate over Wi-Fi using mDNS service types `_mwdat._tcp` and `_mwdat._udp`. If the stream never starts:
1. Check that `NSBonjourServices` in `Info.plist` lists both services.
2. Ensure the iPhone and glasses are on the **same Wi-Fi network**.
3. On first launch, iOS shows a "Local Network" permission dialog — confirm the user has granted it. If they dismissed it, go to **Settings → Privacy & Security → Local Network → MaxAIAssistant**.
4. Corporate or guest Wi-Fi networks often block mDNS — test on a personal hotspot.

**Bluetooth background mode**

The app uses `bluetooth-peripheral` and `external-accessory` background modes (defined in `Info.plist`). If the glasses disconnect when the app is backgrounded:
- Ensure no restriction in **Settings → MaxAIAssistant → Background App Refresh**.

**StreamSession never starts / quick capture**

`ContentView` has two camera paths:
- *Full streaming* — `StreamSession` with `videoFramePublisher` / `photoDataPublisher`
- *Quick capture* — lower frame rate, fires `capturePhoto` on `.starting`/`.streaming`

If frames are not arriving, add a breakpoint on the `videoFramePublisher` sink or log the `StreamSession` state transitions.

---

## 2. Speech Recognition & Wake Word ("Hey Max")

### Symptoms
- "Hey Max" is detected but no response
- "Speech permission denied" status text
- Microphone seems to stop after TTS plays
- "No speech detected" restarts constantly

### Root causes and fixes

**Permission not granted**

`SpeechManager.startListening()` calls `SFSpeechRecognizer.requestAuthorization`. If status is not `.authorized`, the status text reads "Speech permission denied — enable in Settings". Fix: **Settings → Privacy & Security → Speech Recognition → MaxAIAssistant** and **Settings → Privacy & Security → Microphone → MaxAIAssistant**.

**0-channel audio input after TTS**

This is a known issue addressed directly in `SpeechManager.swift`. After `AVSpeechSynthesizer` finishes, audio routing can leave the `AVAudioEngine`'s input node in a 0-channel state. The fix is already implemented: the engine is **torn down and recreated fresh** after each TTS completion (with a 1.2 second delay). If you are seeing `AVAudioBuffer mDataByteSize == 0` warnings in the console:
1. Verify `speechSynthesizer(_:didFinish:)` is firing (add a log).
2. Verify the 1.2-second delay is being respected before `beginSession()` is called.
3. Do not reduce the 1.2-second delay — shorter values reliably reproduce the bug.

**Recogniser returns nil**

`SFSpeechRecognizer(locale:)` returns nil for unsupported locales. The app reads `speechLocale` from `UserDefaults` (default `en-US`). If a user set an unsupported locale:
- Check the console for `[SpeechManager] Session error:`.
- Reset via: `UserDefaults.standard.removeObject(forKey: "speechLocale")`.

**Wake word false negatives**

The wake word check is `text.contains("hey max")` on the lowercased transcription. Ambient noise or strong accents may cause transcription errors (e.g. "hey backs"). There is no fuzzy matching — this is a known limitation.

**Awake stage timeout**

After detecting "Hey Max", the app enters `.awake` for **6 seconds**. If no final transcription arrives, it resets to `.idle`. Ensure the user speaks their query within 6 seconds of the wake word.

**Locale mismatch for TTS**

`SpeechManager.speak()` selects a voice using `AVSpeechSynthesisVoice(language: speechLocale)`. If the response sounds robotic or in the wrong language, verify `speechLocale` matches the desired output language.

---

## 3. OpenAI API Errors

### Symptoms
- "Add your OpenAI API key in Settings" alert
- Chat bubbles never appear / spinner stays on
- HTTP 401 or 429 error in console

### Error codes (from `OpenAIService.ServiceError`)

| Error | Message | Fix |
|---|---|---|
| `missingAPIKey` | "Add your OpenAI API key in Settings." | Open Settings sheet, paste key from [platform.openai.com/api-keys](https://platform.openai.com/api-keys) |
| `httpError(401)` | "Invalid API key" | Key is malformed or revoked — regenerate on the OpenAI dashboard |
| `httpError(429)` | "OpenAI quota exceeded" | Add billing credits at [platform.openai.com/billing](https://platform.openai.com/billing) |
| `httpError(_)` | "OpenAI error N" | Check [status.openai.com](https://status.openai.com) for outages; retry |
| `decodingFailed` | "Could not read the AI response" | The response JSON was malformed — enable debug mode to capture `rawJSON` |
| `imageEncodingFailed` | "Failed to encode the camera frame" | The `UIImage` passed to `chatFull` could not be JPEG-encoded — check image is valid |

### JSON mode parse failures

`AgentBrain.parseGPTResponse()` expects `{"answer": "…", "followUps": […]}`. If GPT wraps the JSON in a markdown code fence, the fallback stripper handles it. If parsing still fails:
- Enable **debug mode** in the UI — the raw GPT response is captured in `DebugInfo.rawResponse`.
- Check `[AgentBrain] JSON parse failed` in the console.

### Timeout

`URLRequest.timeoutInterval` is set to **25 seconds**. On slow networks, vision calls (base64 image payload) may time out. Consider increasing it, or reducing `compressionQuality` below 0.6 to shrink the payload.

### Model context window

All calls use `gpt-4o-mini` with `max_tokens: 250` for main chat responses. If answers are being cut off, this limit may be too low for detailed queries — increase cautiously as it affects cost and latency.

---

## 4. Serper Web / News Search

### Symptoms
- Search results never appear
- Location follows wrong country
- News results are stale

### Debugging steps

**No API key**

`SerperService.search()` reads the key from `UserDefaults.standard.string(forKey: "serper_api_key")`. If missing, it logs `[Serper] No API key — add one in Settings` and returns `[]`. Add the key in the Settings sheet.

**Wrong country results (`gl` parameter)**

The country-code resolution pipeline runs in this order:
1. Stored facts (via `SerperService.countryCode(from:queryHint:)`)
2. GPT micro-agent on the raw query text (`OpenAIService.extractCountryCode`)
3. Default `"us"`

If results are for the wrong country:
- Check stored facts for location strings: `[AgentBrain] Country code extracted by AI and stored: xx`
- Tell Max your location directly in conversation: "I live in [city/country]" — this stores a fact and will be used on subsequent searches.

**No search triggered despite explicit request**

`OpenAIService.classifyIntent()` determines whether to call Serper. If the intent classifies as `.chat` instead of `.search`, no search is made. Look for `[OpenAI] Intent: 'chat'` in the console when you expected `.search`. Try phrasing more explicitly: "Search online for…" or "Google…".

**Empty query after cleaning**

`AgentBrain.cleanSearchQuery()` strips intent preambles. If the remaining string is entirely trivial words (e.g. "search online for this"), `isGenericSearchPhrase()` returns true and the search is skipped with `[AgentBrain] Search skipped — query resolved to empty string`. When an image is present, the app falls back to `OpenAIService.describeImageForSearch()` to generate the query from the image.

**Stale news**

The news endpoint appends `"tbs": "qdr:d"` to restrict results to the last 24 hours. If results seem old, verify Serper's news index freshness at [serper.dev/docs](https://serper.dev/docs).

---

## 5. Memory System (MemoryStore / VisualMemoryStore)

### Symptoms
- Max doesn't remember things said in previous sessions
- Max keeps asking about things that were already mentioned
- Duplicate facts appearing in the Memories view
- Visual memory search returns no results for something definitely saved

### Text memory debugging

**Files corrupted or missing**

Memory is stored in three JSON files:
- `Documents/max_facts.json`
- `Documents/max_episodes.json`
- `Documents/max_summaries.json`

Access them via Xcode → **Window → Devices and Simulators → [device] → Download Container**. Inspect the files to verify content. If a file is malformed, the `JSONDecoder` silently falls back to `[]` — all memory will appear wiped on next launch.

**NLEmbedding unavailable**

On launch, check for:
```
[MemoryStore] NLEmbedding unavailable — recency fallback only ⚠️
```
This occurs on devices where `NLEmbedding.sentenceEmbedding(for: .english)` returns `nil` (language data not downloaded). In this state, semantic retrieval falls back to the 2 most recent episodes only. To fix: ensure the device has English NLP data (it downloads automatically but may not be present on first install or on non-English devices).

**Embeddings must run on main thread**

`MemoryStore.embeddingOnMainThread(for:)` always dispatches embedding calls to the main thread. If you see a hang during memory writes, check for main-thread blocking in `serialQueue.sync` calls from the main thread — the queue is a serial utility queue, and `serialQueue.sync` from main thread should only be used in read paths.

**Facts not being extracted**

After each turn, `AgentBrain.extractAndStoreFactsWithAI()` calls OpenAI. If facts are not appearing:
- Check `[AgentBrain] AI-extracted fact:` log lines.
- If missing, verify the OpenAI key is valid (fact extraction uses the same service).

**Duplicate facts**

The deduplication check uses embedding cosine similarity ≥ 0.85. If two semantically different phrasings are scoring below this threshold, they both get stored. The `consolidateFacts()` background pass (triggers when facts > 12) will merge them via an AI call. Force it by calling `MemoryStore.shared.consolidateFacts()` in a debug session.

### Visual memory debugging

**Visual memory not found by search**

`VisualMemoryStore.contextForQuery()` runs two passes:
1. Direct object inventory search (exact substring in `aiObjects`)
2. Broad keyword search across all text fields

If an item is not found, the object inventory for that memory may not include it. View the raw `index.json` via container download to inspect what objects were recorded. The object inventory quality depends on GPT-4o-mini's vision analysis — re-saving the image (delete and re-tap "Remember This") will generate a fresh inventory.

**Location name missing**

If visual memories have no location label, `LocationManager` either did not have permission, or the GPS fix timed out. Grant location permission and ensure you are not in airplane mode when saving a memory.

**Image file missing**

`VisualMemoryStore.loadImage(for:)` reads from `Documents/VisualMemories/vm_<UUID>.jpg`. If the image doesn't display but the metadata is present in `index.json`, the JPEG write may have failed (out of storage). Check available device storage.

---

## 6. Location & Reverse Geocoding

### Symptoms
- No location tag on visual memories
- Location permission dialog never appears

### Debugging steps

1. `LocationManager` is `@MainActor` and uses `CLLocationManager`. All delegate callbacks bridge back to the main actor via `Task { @MainActor in … }`.
2. Permission must be **"While Using the App"** — the app requests `.requestWhenInUseAuthorization()`.
3. Reverse geocoding uses `CLGeocoder.reverseGeocodeLocation()` — this requires an active internet connection. If offline, geocoding silently returns `nil` and the memory saves without a location label.
4. The label format is `subLocality, locality` (e.g. "Hashmona'im, Ramat Gan") — `thoroughfare` and street numbers are intentionally excluded.

---

## 7. Photo Library Saves

### Symptoms
- "Remember This" saves to the app but not to the Camera Roll
- Photos permission dialog never appears

### Debugging steps

`VisualMemoryStore.saveToPhotoLibrary()` requests `.addOnly` authorization via `PHPhotoLibrary.requestAuthorization(for: .addOnly)`. This is less invasive than full library access — it only allows adding, not reading.

If the image does not appear in the Camera Roll:
- Check **Settings → Privacy & Security → Photos → MaxAIAssistant** — it should show "Add Photos Only".
- Console will show `[VisualMemory] Camera roll save failed: …` if the `PHAssetChangeRequest` fails.
- The app's own copy in `Documents/VisualMemories/` is unaffected by Photos permission.

---

## 8. Build & Xcode Issues

### Swift Package Resolution Fails

The only external package is `meta-wearables-dat-ios` from `https://github.com/facebook/meta-wearables-dat-ios` pinned to v0.5.0 (revision `2ea30fa228359315baf71c404aec821472e994c1`). If resolution fails:
1. Check internet connectivity.
2. **File → Packages → Reset Package Caches**
3. Delete `MaxAIAssistant.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` and re-resolve.

### Deployment Target Mismatch

The project targets **iOS 26.2** (`IPHONEOS_DEPLOYMENT_TARGET = 26.2`). Xcode 26 / iOS 26 are required. Running on an older Xcode or simulator version will produce deployment target warnings or build errors.

### `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`

This project-wide setting means **all types are implicitly `@MainActor`** unless explicitly marked otherwise (`nonisolated`, `Task.detached`). If you add code that must run off the main thread, annotate it explicitly — otherwise it will silently run on the main thread and may cause deadlocks with `serialQueue.sync` in `MemoryStore`.

### Code Signing

The development team is configured as Automatic. If you see signing errors, select your personal team in the target's **Signing & Capabilities** tab.

---

## 9. General Debugging Tips

**Enable debug mode in the UI**

Tap the debug toggle in the Settings sheet. Each assistant `ChatMessage` will then populate `debugInfo` with:
- Full system prompt sent to GPT
- Memory tier counts (facts / episodes / summaries)
- Raw GPT JSON response
- Processing time (ms)
- Token usage (prompt + completion)

**Console log prefixes**

Every subsystem prefixes its log output:

| Prefix | Source |
|---|---|
| `[AgentBrain]` | AI orchestration, intent, memory triggers |
| `[OpenAI]` | HTTP calls, intent classification, token errors |
| `[MemoryStore]` | Memory reads/writes, deduplication, summarisation |
| `[VisualMemory]` | Image saves, object inventory, search results |
| `[SpeechManager]` | Wake word, TTS, session start/stop |
| `[Serper]` | Search calls, country code, result count |
| `[LocationManager]` | Not prefixed — search for `CLGeocoder` errors |

**Memory file inspection**

Use Xcode's **Devices and Simulators** window to download the app container and inspect:
- `Documents/max_facts.json`
- `Documents/max_episodes.json`
- `Documents/max_summaries.json`
- `Documents/VisualMemories/index.json`

**Reset all memory (nuclear option)**

Call `MemoryStore.shared.clear()` from a debug breakpoint or temporary UI button to wipe all three tiers. Visual memories must be deleted individually via the gallery view (or by deleting `Documents/VisualMemories/`).

**Simulate glasses without hardware**

The package includes `MWDATMockDevice`. Use it in the simulator or for unit testing to simulate device discovery and frame delivery without physical glasses connected.
