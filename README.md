# Max AI Assistant

An iOS companion app for **Ray-Ban Meta smart glasses** that provides a persistent, memory-aware AI assistant with live vision, voice activation, web search, and a searchable visual memory gallery.

> **Try it now — no Xcode required**
> [![TestFlight](https://img.shields.io/badge/TestFlight-Beta-blue?logo=apple)](https://testflight.apple.com/join/781dSq1G)
> Install the [TestFlight app](https://apps.apple.com/app/testflight/id899247664) on your iPhone, then tap the link above to join the beta.
> Requires iOS 26.2 · iPhone with Bluetooth + Ray-Ban Meta glasses recommended (works without glasses in chat-only mode)

---

## Table of Contents

- [Overview](#overview)
- [System Architecture](#system-architecture)
- [Core Technologies](#core-technologies)
- [Project Structure](#project-structure)
- [Data Flow](#data-flow)
- [Memory System](#memory-system)
- [Prerequisites](#prerequisites)
- [Setup & Installation](#setup--installation)
- [Configuration](#configuration)
- [Permissions Required](#permissions-required)
- [Security Notes](#security-notes)

---

## Overview

Max is a wearable AI assistant that lives on your iPhone and connects to Ray-Ban Meta glasses. The user speaks "Hey Max" to activate it hands-free, points the glasses camera at anything to ask about it, and receives spoken answers. Every conversation is remembered across sessions using a tiered semantic memory system. "Visual memories" — photos taken through the glasses — are indexed with AI-generated object inventories and can be queried later (e.g., "where did I leave my keys?").

---

## System Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│  MaxAIAssistantApp  (App entry — configures MWDATCore, handles OAuth)│
└───────────────────────────────┬─────────────────────────────────────┘
                                │
                    ┌───────────▼────────────┐
                    │     ContentView         │  ← Primary SwiftUI view
                    │  (1 700+ lines)         │    Glasses stream, chat UI,
                    │                         │    toolbar, settings sheets
                    └───┬────────┬────────────┘
                        │        │
          ┌─────────────▼─┐  ┌───▼──────────────┐
          │  MWDATCore /   │  │   SpeechManager   │
          │  MWDATCamera   │  │  "Hey Max" wake   │
          │  (Meta SDK)    │  │  word + TTS       │
          └─────────────┬─┘  └───────────────────┘
                        │ live frames / photos
                        ▼
          ┌─────────────────────────────────────┐
          │             AgentBrain               │  ← @MainActor singleton
          │   Parallel: classifyIntent + memory  │    Orchestrates every AI turn
          │   Optional: Serper search / news      │
          │   Visual memory query injection       │
          │   Background: store + extract + mine  │
          └──────┬──────────┬────────────────────┘
                 │          │
    ┌────────────▼──┐   ┌───▼──────────────────────────┐
    │  OpenAIService│   │  MemoryStore (3 tiers)         │
    │  gpt-4o-mini  │   │  Facts / Episodes / Summaries  │
    │  Vision       │   │  NLEmbedding cosine search     │
    │  JSON mode    │   │  JSON files in Documents/      │
    └───────────────┘   └──────────────────────────────┘
                                    │
                    ┌───────────────▼──────────────────┐
                    │  VisualMemoryStore                 │
                    │  Images + index.json               │
                    │  Documents/VisualMemories/         │
                    │  Object inventory search           │
                    │  LocationManager (reverse geocode) │
                    └──────────────────────────────────┘
                                    │
                        ┌───────────▼──────────┐
                        │    SerperService       │
                        │  google.serper.dev     │
                        │  /search and /news     │
                        │  Country-code resolver │
                        └──────────────────────┘
```

---

## Core Technologies

| Category | Technology | Version / Notes |
|---|---|---|
| Language | Swift | 5.0, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` |
| UI Framework | SwiftUI + UIKit | iOS 26.2 deployment target |
| Concurrency | Swift Structured Concurrency | `async/await`, `Task.detached`, `@MainActor` |
| Glasses SDK | `meta-wearables-dat-ios` (MWDATCore, MWDATCamera, MWDATMockDevice) | v0.5.0 via Swift Package Manager |
| AI | OpenAI Chat Completions API | `gpt-4o-mini`, JSON mode, vision (base64 JPEG) |
| Web Search | Serper.dev | `/search` and `/news` endpoints |
| Semantic Memory | Apple `NaturalLanguage.NLEmbedding` | `.sentenceEmbedding(for: .english)` — on-device 512-dim vectors |
| Speech Recognition | Apple `Speech` framework | `SFSpeechRecognizer`, `SFSpeechAudioBufferRecognitionRequest` |
| Text-to-Speech | `AVFoundation.AVSpeechSynthesizer` | Voice matched to selected locale |
| Location | `CoreLocation` + `CLGeocoder` | Reverse geocoding for visual memory labels |
| Photos | `Photos` framework | Add-only permission for camera roll saves |
| Persistence | JSON files in `Documents/` | `JSONEncoder/Decoder`, atomic writes |
| Dependency Management | Swift Package Manager | `Package.resolved` pinned to exact revision |

---

## Project Structure

```
MaxAIAssistant/
├── MaxAIAssistant.xcodeproj/
│   └── project.pbxproj                 # Xcode project (single target)
│
└── MaxAIAssistant/                     # App source root
    ├── MaxAIAssistantApp.swift         # @main entry; configures Wearables SDK
    ├── ContentView.swift               # Primary UI (~1 700 lines)
    ├── AgentBrain.swift                # AI orchestrator singleton
    ├── MaxSoul.swift                   # Persona + system prompt builder
    ├── OpenAIService.swift             # OpenAI HTTP client + all AI helpers
    ├── MemoryStore.swift               # 3-tier text memory (facts/episodes/summaries)
    ├── VisualMemoryStore.swift         # Image memory + LocationManager
    ├── VisualMemoriesView.swift        # Gallery + detail view for visual memories
    ├── SpeechManager.swift             # Wake word detection + TTS coordinator
    ├── SerperService.swift             # Web/news search + ThumbnailCache
    ├── Info.plist                      # URL schemes, Meta SDK config, permissions
    ├── Assets.xcassets/                # App icon, accent colour
    └── metaglassesIcon.webp            # UI asset
```

**Root-level files (not part of the Xcode target):**
```
brainIdea.txt     # Design notes (on-device Foundation Models approach — not yet implemented)
logs.txt          # Empty placeholder
metaglassesIcon.webp
raybanGlasses.webp
```

---

## Data Flow

### Conversation Turn (Happy Path)

```
User speaks "Hey Max, what is this?"
        ↓
SpeechManager detects wake word → fires query string
        ↓
ContentView captures camera frame (or uses last photo)
        ↓
AgentBrain.respond(to: query, image: frame)
    ├── [parallel] OpenAIService.classifyIntent()   → .vision / .search / .news / .chat
    └── [parallel] MemoryStore.context(for: query)  → facts + episodes + summaries
        ↓
    [if .search/.news] SerperService.search()
    [always]           VisualMemoryStore.contextForQuery()
        ↓
    MaxSoul.buildSystemPrompt()  →  system message with persona + all memory tiers
        ↓
    OpenAIService.chatFull()  →  { answer, followUps }  (JSON mode)
        ↓
    ChatMessage appended to chatHistory (Published → UI updates)
        ↓
    SpeechManager.speak(answer)  →  TTS plays response
        ↓
    [background Task]
        ├── MemoryStore.add(qa episode)
        ├── OpenAIService.extractFacts()  → MemoryStore.add(facts)
        ├── [if 10+ new episodes] runEpisodeMining()
        ├── [if word count > 2 000] runSummarization()
        └── [if facts > 12] MemoryStore.consolidateFacts()
```

### Visual Memory Save

```
User taps "Remember This" on a captured frame
        ↓
LocationManager.fetchLocation()  →  reverse-geocoded label + coordinates
        ↓
OpenAIService.analyzeVisualMemory(image, locationName, userFacts)
    →  { summary, description, tags, objects[] }   (detail: "high")
        ↓
VisualMemoryStore.save(image, …metadata…)
    ├── Writes JPEG to Documents/VisualMemories/vm_<UUID>.jpg
    ├── Inserts VisualMemory into index.json
    └── PHPhotoLibrary add-only save → Camera Roll
```

---

## Memory System

Max uses a **three-tier memory architecture** persisted as JSON files in the app's Documents directory:

| Tier | File | Contents | Prompt inclusion |
|---|---|---|---|
| **1 — Facts** | `max_facts.json` | Personal profile: names, relationships, preferences, location | Always — up to 25 most recent |
| **2 — Episodes** | `max_episodes.json` | QA pairs from past conversations | Semantic top-4 + 2 most recent |
| **3 — Summaries** | `max_summaries.json` | AI-compressed episode chapters | Always — up to 3 most recent |

**Automatic maintenance (all background tasks):**

- **Fact deduplication on write** — embedding cosine similarity ≥ 0.85 or keyword overlap ≥ 2 triggers replacement instead of append.
- **Episode mining** — every 10 new episodes, a background pass scans unreviewed QA pairs to elevate missed personal facts.
- **Episode summarisation** — when episode text exceeds ~2 000 words, the oldest 40 episodes are compressed by GPT into a summary chapter.
- **Fact consolidation** — when facts exceed 12 entries, an AI pass deduplicates and merges them.

---

## Beta Testing (TestFlight)

The fastest way to try Max AI Assistant is via the public TestFlight beta — no Xcode, no Apple Developer account needed.

| Step | Action |
|---|---|
| 1 | Install **[TestFlight](https://apps.apple.com/app/testflight/id899247664)** from the App Store |
| 2 | Open **[https://testflight.apple.com/join/781dSq1G](https://testflight.apple.com/join/781dSq1G)** on your iPhone |
| 3 | Tap **Accept** → **Install** |
| 4 | Open Max, go to **Settings**, and paste your OpenAI API key |
| 5 | (Optional) Add a Serper API key for web/news search |
| 6 | Put on your Ray-Ban Meta glasses and say **"Hey Max"** |

**Minimum requirements:** iPhone running iOS 26.2 · Ray-Ban Meta Gen 2 glasses (optional — the app works in chat-only mode without glasses)

**Sending feedback:** Shake your iPhone while in the app, or use the TestFlight app's **Send Beta Feedback** button. Crash reports are forwarded automatically.

---

## Prerequisites

- **macOS** with **Xcode 26.2** (or later)
- **Apple Developer account** (any paid plan — required for physical device deployment)
- **iPhone** running **iOS 26.2** or later
- **Ray-Ban Meta glasses** (Gen 2 or later) + the **Meta View app** installed on the same iPhone
- **OpenAI API key** — obtain at [platform.openai.com/api-keys](https://platform.openai.com/api-keys)
- **Serper API key** (optional, for web/news search) — obtain at [serper.dev](https://serper.dev)

---

## Setup & Installation

1. **Clone the repository:**
   ```bash
   git clone <repo-url>
   cd MaxAIAssistant
   ```

2. **Open in Xcode:**
   ```bash
   open MaxAIAssistant.xcodeproj
   ```
   Xcode will automatically resolve the `meta-wearables-dat-ios` Swift package (requires internet access).

3. **Select your development team:**
   - In Xcode: select the `MaxAIAssistant` target → **Signing & Capabilities**
   - Change the Team to your own Apple Developer account

4. **Connect your iPhone** and select it as the run destination.

5. **Build & Run** (`⌘R`).

6. **First launch — enter your API keys:**
   - Tap the **Settings** (gear) icon inside the app
   - Enter your **OpenAI API key**
   - (Optional) Enter your **Serper API key** for web search

7. **Pair your glasses:**
   - Tap **Connect Glasses** in the app
   - The app will open (or prompt you to install) the **Meta View** app to complete OAuth pairing
   - After authorisation, the Meta View app redirects back to Max via the `maxaiassistant://` URL scheme

---

## Configuration

All runtime configuration is stored in `UserDefaults` via SwiftUI `@AppStorage`. There are no build-time secrets or `.xcconfig` files required by end users.

| Key | Where set | Purpose |
|---|---|---|
| `openai_api_key` | Settings sheet | OpenAI API authentication |
| `serper_api_key` | Settings sheet | Serper web/news search |
| `speechLocale` | Settings sheet | Speech recognition locale (default `en-US`) |
| `max_agent_preferences_v2` | Auto-extracted from conversation | User name, detail level, preferred language |
| `maxMemoryLastMining_v1` | Automatic | Timestamp of last retrospective episode mining pass |

---

## Permissions Required

The app requests the following iOS permissions at runtime. All usage description strings are defined in `Info.plist`.

| Permission | Usage |
|---|---|
| **Bluetooth Always** | Connect to Ray-Ban Meta glasses |
| **Local Network** | Stream video from glasses over Wi-Fi (`_mwdat._tcp`, `_mwdat._udp`) |
| **Camera** | Access the glasses camera for live streaming |
| **Microphone** | Listen for "Hey Max" wake word |
| **Speech Recognition** | Transcribe voice commands |
| **Location (When In Use)** | Tag visual memories with reverse-geocoded location labels |
| **Photo Library (Add Only)** | Save visual memories to the Camera Roll |

---

## Security Notes

- **API keys are never hardcoded.** OpenAI and Serper keys are entered by the user at runtime and stored in `UserDefaults` (device-local, not synced to iCloud).
- **`Info.plist` contains Meta SDK credentials** (`ClientToken`, `MetaAppID`) in plaintext. These are required by the Meta Wearables SDK and tie the app to a registered Meta developer application. Do not expose this file publicly if you are distributing under your own Meta App ID.
- **No data leaves the device** except for API calls to `api.openai.com` and `google.serper.dev`. All memory files are stored locally under the app sandbox (`Documents/`).
- **Image data** sent to OpenAI is base64-encoded JPEG at reduced quality (60–70%) and is subject to OpenAI's data usage policies.
