import SwiftUI
import MWDATCore
import MWDATCamera
import Network
import CoreLocation

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase

    // MARK: - Stream state
    @State private var statusMessage  = "Ready to Connect"
    @State private var currentFrame:  UIImage?  = nil
    @State private var streamSession: StreamSession?
    @State private var isStreaming    = false
    /// Guards against double-start: set true while discovery/setup is in progress.
    @State private var isConnecting   = false

    // Listener tokens — must be retained or callbacks are immediately cancelled
    @State private var devicesToken:   (any AnyListenerToken)?
    @State private var frameToken:     (any AnyListenerToken)?
    @State private var stateToken:     (any AnyListenerToken)?
    @State private var errorToken:     (any AnyListenerToken)?
    @State private var photoDataToken: (any AnyListenerToken)?

    // MARK: - Photo state
    @State private var capturedPhoto:      UIImage?
    @State private var isCapturing         = false
    @State private var quickSession:       StreamSession?
    @State private var quickStateToken:    (any AnyListenerToken)?
    @State private var quickPhotoToken:    (any AnyListenerToken)?
    @State private var quickFrameToken:    (any AnyListenerToken)?
    // Guard to ensure one capturePhoto call per quick session.
    @State private var quickCaptureRequested = false
    // Cached so subsequent quickCaptures skip device discovery this session
    @State private var cachedDeviceId:     DeviceIdentifier?
    // Hard timeout — cancelled when photo arrives, fires if glasses don't respond
    @State private var captureTimeoutTask: Task<Void, Never>?

    // MARK: - AI & speech
    @StateObject private var speechManager = SpeechManager()
    @StateObject private var brain         = AgentBrain.shared
    @State private var aiResponse          = ""
    @State private var isAnalyzing         = false
    @State private var textInput           = ""
    @FocusState private var isInputFocused: Bool

    // MARK: - Sheet / navigation
    @AppStorage("serper_api_key") private var serperKey    = ""
    @AppStorage("debugMode")      private var debugMode    = false
    @AppStorage("speechLocale")   private var speechLocale = "en-US"
    @AppStorage(AIProvider.selectedDefaultsKey) private var selectedProviderRaw = AIProvider.openAI.rawValue
    @AppStorage("openai_model") private var openAIModel = AIProvider.openAI.defaultModel
    @AppStorage("gemini_model") private var geminiModel = AIProvider.gemini.defaultModel
    @State private var openAIKeyInput = ""
    @State private var geminiKeyInput = ""
    @State private var showSettings    = false
    @State private var showPhotoAsk    = false
    // Internal flag used when auto-capturing a frame for "what do I see" style queries.
    // Prevents the photo ask sheet from popping while we are capturing only for analysis.
    @State private var suppressPhotoAskForAutoVision = false

    // MARK: - Destructive action confirmation
    @State private var confirmClearMemory  = false
    @State private var confirmResetSession = false

    // MARK: - Visual memories
    @State private var showVisualMemories  = false
    @State private var isSavingMemory      = false
    @State private var resumeMicAfterCapture = false
    @State private var micAutoStartedByStream = false
    // Dedup guards for auto-indexing captures into visual memory.
    @State private var autoIndexedCaptureKeys: Set<String> = []
    @State private var autoIndexingCaptureKeys: Set<String> = []

    // MARK: - Body

    /// True when there is active visual content to display in the viewfinder.
    private var hasActiveMedia: Bool {
        capturedPhoto != nil || currentFrame != nil || isCapturing || isStreaming
    }

    private var selectedProvider: AIProvider {
        AIProvider(rawValue: selectedProviderRaw) ?? .openAI
    }

    private func persistAISettings() {
        selectedProviderRaw = selectedProvider.rawValue
        let openAITrimmed = openAIKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let geminiTrimmed = geminiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if openAITrimmed.isEmpty {
            KeychainHelper.delete(key: KeychainHelper.openAIKeyName)
        } else {
            KeychainHelper.write(key: KeychainHelper.openAIKeyName, value: openAITrimmed)
        }
        if geminiTrimmed.isEmpty {
            KeychainHelper.delete(key: KeychainHelper.geminiKeyName)
        } else {
            KeychainHelper.write(key: KeychainHelper.geminiKeyName, value: geminiTrimmed)
        }
    }

    private func loadAISettingsFromKeychain() {
        openAIKeyInput = KeychainHelper.read(key: KeychainHelper.openAIKeyName) ?? ""
        geminiKeyInput = KeychainHelper.read(key: KeychainHelper.geminiKeyName) ?? ""
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                // ── Main scroll ───────────────────────────────────────────────
                ScrollView {
                    VStack(spacing: 0) {
                        // Header — compact when chat-only, full when media is active
                        if hasActiveMedia {
                            headerView
                            viewfinderView
                                .transition(.move(edge: .top).combined(with: .opacity))
                        } else {
                            compactHeaderView
                        }
                        chatView
                        controlsView
                    }
                    .padding(.bottom, 88)   // room for input toolbar
                }
                .animation(.easeInOut(duration: 0.3), value: hasActiveMedia)
                // Dismiss keyboard on scroll or tap anywhere outside the input bar
                .scrollDismissesKeyboard(.interactively)
                .onTapGesture { isInputFocused = false }

                // ── Floating input bar ────────────────────────────────────────
                VStack(spacing: 0) {
                    if speechManager.isListening {
                        listeningPill
                            .padding(.bottom, 4)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    textInputBar
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    HStack(spacing: 14) {
                        // Text memories
                        NavigationLink { MemoriesView() } label: {
                            Image(systemName: "brain")
                        }
                        // Visual memories
                        Button { showVisualMemories = true } label: {
                            ZStack(alignment: .topTrailing) {
                                Image(systemName: "photo.stack.fill")
                                if !VisualMemoryStore.shared.memories.isEmpty {
                                    Circle().fill(Color.blue)
                                        .frame(width: 7, height: 7)
                                        .offset(x: 2, y: -2)
                                }
                            }
                        }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gear") }
                }
            }
            .sheet(isPresented: $showSettings) { settingsSheet }
            .sheet(isPresented: $showPhotoAsk) { photoAskSheet }
            .sheet(isPresented: $showVisualMemories) { VisualMemoriesView() }
            .onAppear {
                speechManager.onWakeWordQuery = { q in handleQuery(q, image: nil) }
                // Sync persisted locale to speech manager on launch
                speechManager.speechLocale = speechLocale
                loadAISettingsFromKeychain()
            }
            .onChange(of: isStreaming) { _, streaming in
                // Route continuous wake listening through the glasses microphone
                // whenever the glasses stream is connected.
                if streaming {
                    if !speechManager.isListening {
                        speechManager.onWakeWordQuery = { q in handleQuery(q, image: nil) }
                        speechManager.startContinuousWakeListening(preferBluetoothHFP: true)
                        micAutoStartedByStream = true
                    }
                } else {
                    // Do not forcibly stop wake listening on stream disconnect.
                    // Users expect the mic toggle intent to persist across reconnects.
                    micAutoStartedByStream = false
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    // Recover from background/audio interruptions where UI may still
                    // show active intent but session was torn down by the system.
                    if speechManager.isContinuousWakeRequested && !speechManager.isListening {
                        speechManager.onWakeWordQuery = { q in handleQuery(q, image: nil) }
                        speechManager.resumeContinuousWakeListeningIfRequested()
                    }
                }
            }
            .animation(.easeInOut(duration: 0.2), value: speechManager.isListening)
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(alignment: .center) {
            Spacer()
            VStack(spacing: 2) {
                Text("MAX AI STUDIOS")
                    .font(.system(size: 26, weight: .black, design: .rounded))
                Text("Vision Assistant")
                    .font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            // Start New Chat — clears the screen; long-term memories stay intact
            Button(action: startNewChat) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.trailing, 8)
        }
        .padding(.top, 12).padding(.bottom, 8)
    }

    /// One-line header shown when no media is active (chat fills screen).
    private var compactHeaderView: some View {
        HStack(spacing: 6) {
            Text("MAX")
                .font(.system(size: 15, weight: .black, design: .rounded))
            Text("AI Studios")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
            // Start New Chat
            Button(action: startNewChat) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8).padding(.bottom, 4)
    }

    /// Clears the current chat screen and saves the session to long-term memory.
    private func startNewChat() {
        // Trigger summarization if the session was large enough, then clear
        Task.detached(priority: .background) {
            if MemoryStore.shared.needsSummarization {
                await AgentBrain.runSummarization()
            }
        }
        brain.clearSession()
    }

    // MARK: - Viewfinder

    private var viewfinderView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20)
                .fill(Color.black.opacity(0.06))
                .frame(height: 300)

            Group {
                if let photo = capturedPhoto        { capturedPhotoView(photo) }
                else if let frame = currentFrame    { liveStreamView(frame)    }
                else                                { placeholderView          }
            }

            if isAnalyzing || isCapturing {
                RoundedRectangle(cornerRadius: 20).fill(Color.black.opacity(0.5)).frame(height: 300)
                VStack(spacing: 10) {
                    ProgressView().tint(.white)
                    Text(isCapturing ? "Capturing photo…" : (aiResponse.isEmpty ? "Thinking…" : aiResponse))
                        .font(.headline).foregroundColor(.white)
                        .multilineTextAlignment(.center).padding(.horizontal)
                }
            }
        }
        .padding(.horizontal)
    }

    private func liveStreamView(_ image: UIImage) -> some View {
        Image(uiImage: image)
            .resizable().aspectRatio(contentMode: .fill)
            .frame(height: 300).clipShape(RoundedRectangle(cornerRadius: 20))
            .overlay(alignment: .topLeading) { liveBadge }
            .overlay(alignment: .bottomTrailing) {
                HStack(spacing: 8) {
                    // Remember current frame as a visual memory
                    Button(action: { rememberPhoto(image) }) {
                        Label(isSavingMemory ? "Saving…" : "Remember",
                              systemImage: isSavingMemory ? "hourglass" : "bookmark.fill")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Color.orange.opacity(0.88)).foregroundColor(.white)
                            .cornerRadius(20)
                    }
                    .disabled(isSavingMemory)

                    Button(action: captureSDKPhoto) {
                        Label("Capture", systemImage: "camera.viewfinder")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(.ultraThinMaterial).cornerRadius(20)
                    }
                }
                .padding(12)
            }
    }

    private func capturedPhotoView(_ photo: UIImage) -> some View {
        ZStack(alignment: .topTrailing) {
            Image(uiImage: photo)
                .resizable().aspectRatio(contentMode: .fill)
                .frame(height: 300).clipShape(RoundedRectangle(cornerRadius: 20))
                .overlay(alignment: .topLeading) { snapBadge }

            VStack(spacing: 8) {
                Button { capturedPhoto = nil } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3).foregroundColor(.white).shadow(radius: 2)
                }
                Button { showPhotoAsk = true } label: {
                    Label("Ask", systemImage: "bubble.left.and.text.bubble.right.fill")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Color.blue).foregroundColor(.white).cornerRadius(20)
                }
                Button { startVoiceForPhoto() } label: {
                    Label("Voice", systemImage: "mic.fill")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Color.green).foregroundColor(.white).cornerRadius(20)
                }
                // Remember This — saves with AI analysis + location
                Button { rememberPhoto(photo) } label: {
                    if isSavingMemory {
                        HStack(spacing: 6) {
                            ProgressView().tint(.white).scaleEffect(0.7)
                            Text("Saving…").font(.caption.weight(.semibold))
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Color.orange).foregroundColor(.white).cornerRadius(20)
                    } else {
                        Label("Remember This", systemImage: "bookmark.fill")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Color.orange).foregroundColor(.white).cornerRadius(20)
                    }
                }
                .disabled(isSavingMemory)
            }
            .padding(10)
        }
    }

    /// Saves the captured photo as a visual memory with AI description + location.
    @MainActor
    private func rememberPhoto(_ photo: UIImage) {
        guard !isSavingMemory else { return }
        isSavingMemory = true
        Task { @MainActor in
            // Fetch location with a 5-second timeout so we never hang forever
            let (locationName, coord) = await fetchLocationWithTimeout()
            // Keep roll save idempotent and ensure manual remember includes location metadata.
            VisualMemoryStore.shared.saveCaptureToPhotoLibrary(
                image: photo,
                latitude: coord?.latitude,
                longitude: coord?.longitude
            )
            await createVisualMemoryEntry(
                for: photo,
                locationName: locationName,
                coord: coord,
                includeChatConfirmation: true,
                captureKey: captureKey(for: photo)
            )
            isSavingMemory = false
        }
    }

    /// Lightweight stable key for deduplicating repeated callbacks for the same frame/photo.
    @MainActor
    private func captureKey(for photo: UIImage) -> String {
        guard let data = photo.jpegData(compressionQuality: 0.35) else {
            return "fallback-\(photo.size.width)x\(photo.size.height)"
        }
        let prefix = data.prefix(64).base64EncodedString()
        return "\(data.count)-\(prefix)"
    }

    /// Builds and stores a visual memory entry (AI summary + tags + objects).
    @MainActor
    private func createVisualMemoryEntry(
        for photo: UIImage,
        locationName: String?,
        coord: CLLocationCoordinate2D?,
        includeChatConfirmation: Bool,
        captureKey: String?
    ) async {
        let knownFacts = knownFactsContext()

        let analysis = await AgentBrain.shared.analyzeVisualMemory(
            image: photo,
            locationName: locationName,
            userFacts: knownFacts
        )

        VisualMemoryStore.shared.save(
            image:         photo,
            aiSummary:     analysis.summary,
            aiDescription: analysis.description,
            aiTags:        analysis.tags,
            aiObjects:     analysis.objects,
            locationName:  locationName,
            latitude:      coord?.latitude,
            longitude:     coord?.longitude
        )

        if let key = captureKey {
            autoIndexedCaptureKeys.insert(key)
            if autoIndexedCaptureKeys.count > 200 {
                autoIndexedCaptureKeys = Set(autoIndexedCaptureKeys.suffix(120))
            }
        }

        if includeChatConfirmation {
            let objNote = analysis.objects.isEmpty ? "" : " I indexed \(analysis.objects.count) objects so you can find anything later."
            brain.chatHistory.append(ChatMessage(
                role:      .assistant,
                content:   "Got it! I saved this as \"\(analysis.summary)\".\(locationName.map { " Taken at \($0)." } ?? "")\(objNote)",
                timestamp: Date(),
                hasImage:  false,
                followUps: ["Show my memories", "What's in this photo?", "Where are my keys?"]
            ))
        }
    }

    /// Pull a compact block of known facts to ground AI visual analysis.
    @MainActor
    private func knownFactsContext() -> String? {
        let facts = MemoryStore.shared.all.filter { $0.tags.contains("fact") }
        guard !facts.isEmpty else { return nil }
        return facts.prefix(15).map { "- \($0.text)" }.joined(separator: "\n")
    }

    /// Saves every capture to Camera Roll and auto-indexes it in Visual Memories.
    /// This runs for ALL capture paths, even when the user does not tap "Remember This".
    @MainActor
    private func processCapturedImage(_ photo: UIImage) {
        let key = captureKey(for: photo)
        if autoIndexedCaptureKeys.contains(key) || autoIndexingCaptureKeys.contains(key) { return }
        autoIndexingCaptureKeys.insert(key)

        Task { @MainActor in
            defer { autoIndexingCaptureKeys.remove(key) }
            let (locationName, coord) = await fetchLocationWithTimeout()
            VisualMemoryStore.shared.saveCaptureToPhotoLibrary(
                image: photo,
                latitude: coord?.latitude,
                longitude: coord?.longitude
            )
            // Resume wake listening immediately after the actual capture completes.
            // Do NOT wait for AI indexing/persistence, which can take seconds.
            resumeListeningAfterCaptureIfNeeded()
            await createVisualMemoryEntry(
                for: photo,
                locationName: locationName,
                coord: coord,
                includeChatConfirmation: false,
                captureKey: key
            )
        }
    }

    @MainActor
    private func pauseListeningForCaptureIfNeeded() {
        guard speechManager.isListening else {
            resumeMicAfterCapture = false
            return
        }
        resumeMicAfterCapture = true
        speechManager.pauseListeningTemporarily()
    }

    @MainActor
    private func resumeListeningAfterCaptureIfNeeded() {
        guard resumeMicAfterCapture else { return }
        resumeMicAfterCapture = false
        speechManager.onWakeWordQuery = { q in handleQuery(q, image: nil) }
        speechManager.resumeContinuousWakeListeningIfRequested()
    }

    /// Location fetch with a 5-second timeout; returns (nil, nil) if unavailable or denied.
    @MainActor
    private func fetchLocationWithTimeout() async -> (String?, CLLocationCoordinate2D?) {
        // ResumeOnce guarantees the CheckedContinuation is resumed exactly once even
        // when both the timeout Task and the location callback race.
        // Using a reference type (class) avoids the Swift 6 @Sendable mutable-capture
        // error that crashes when a `var` is captured by two @Sendable closures.
        final class ResumeOnce: @unchecked Sendable {
            var fired = false
        }
        let once = ResumeOnce()

        return await withCheckedContinuation { cont in
            // Timeout: Task.sleep keeps us inside Swift concurrency and avoids
            // mixing GCD with actor-isolated continuations (crash in Swift 6).
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(5))
                guard !once.fired else { return }
                once.fired = true
                cont.resume(returning: (nil, nil))
            }
            LocationManager.shared.fetchLocation { name, coord in
                guard !once.fired else { return }
                once.fired = true
                cont.resume(returning: (name, coord))
            }
        }
    }

    /// Loads the Ray-Ban glasses image directly from the main bundle (webp via Data decode,
    /// avoiding xcassets compilation requirements on first build).
    private var glassesImage: Image {
        if let url  = Bundle.main.url(forResource: "metaglassesIcon", withExtension: "webp"),
           let data = try? Data(contentsOf: url),
           let ui   = UIImage(data: data) {
            return Image(uiImage: ui)
        }
        return Image(systemName: "eyeglasses")
    }

    private var placeholderView: some View {
        VStack(spacing: 12) {
            glassesImage
                .resizable()
                .scaledToFit()
                .frame(width: 300, height: 176)
                .opacity(0.88)

            Text(statusMessage)
                .font(.headline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            if !isCapturing {
                Button(action: quickCapture) {
                    Label("Take Photo from Glasses", systemImage: "camera.fill")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(Color.blue.opacity(0.1))
                        .foregroundColor(.blue)
                        .cornerRadius(12)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.blue.opacity(0.3)))
                }
            }
        }
    }

    private var liveBadge: some View {
        HStack(spacing: 5) {
            Circle().fill(Color.red).frame(width: 8, height: 8)
            Text("LIVE").font(.caption2).bold()
        }
        .padding(8).background(.ultraThinMaterial).cornerRadius(8).padding(12)
    }

    private var snapBadge: some View {
        HStack(spacing: 5) {
            Image(systemName: "camera.fill").font(.caption2)
            Text("SNAPSHOT").font(.caption2).bold()
        }
        .padding(8).background(.ultraThinMaterial).cornerRadius(8).padding(12)
    }

    // MARK: - Chat view

    @ViewBuilder
    private var chatView: some View {
        if !brain.chatHistory.isEmpty || isAnalyzing {
            VStack(alignment: .leading, spacing: 0) {
                // Only show the Chat/trash header when media is also visible
                if hasActiveMedia {
                    HStack {
                        Text("Chat")
                            .font(.caption.weight(.semibold)).foregroundColor(.secondary)
                        Spacer()
                        Button {
                            AgentBrain.shared.clearSession(); aiResponse = ""
                        } label: {
                            Image(systemName: "trash").font(.caption).foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 4)
                }

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(brain.chatHistory) { msg in
                                ChatBubbleView(message: msg, debugMode: debugMode) { followUp in
                                    handleQuery(followUp, image: nil)
                                }
                                .id(msg.id)
                            }
                            if isAnalyzing { TypingIndicatorView().id("typing") }
                        }
                        .padding(.horizontal, 12).padding(.bottom, 8)
                        .padding(.top, hasActiveMedia ? 4 : 8)
                    }
                    // When no media: uncapped so chat fills the full screen
                    // When media is active: cap at 280 to leave room for viewfinder
                    .frame(maxHeight: hasActiveMedia ? 280 : .infinity)
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: brain.chatHistory.count) { _, _ in
                        withAnimation { proxy.scrollTo(brain.chatHistory.last?.id, anchor: .bottom) }
                    }
                    .onChange(of: isAnalyzing) { _, on in
                        if on { withAnimation { proxy.scrollTo("typing", anchor: .bottom) } }
                    }
                }
            }
            .background { if hasActiveMedia { Color.clear.background(.thinMaterial) } }
            .cornerRadius(hasActiveMedia ? 16 : 0)
            .padding(.horizontal).padding(.top, 8)
        }
    }

    // MARK: - Smart input toolbar (iOS-native style)
    //
    // Layout:  ─── text field ─── [📷] [🎬] [🎤] [↑]
    // • 📷  smart photo: quick-capture if idle, SDK capture if streaming
    // • 🎬  live stream toggle  (video.fill active/red · video idle)
    // • 🎤  Hey Max toggle      (green + pulse when listening)
    // • ↑   send                (spring-appears only when text present)

    private var textInputBar: some View {
        VStack(spacing: 0) {
            Divider()

            HStack(alignment: .bottom, spacing: 6) {

                // ── Text field (fills all space) ────────────────────────────
                TextField("Ask Max…", text: $textInput, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .focused($isInputFocused)
                    .font(.body)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .onSubmit { sendTextInput() }

                // ── Right action cluster ────────────────────────────────────
                HStack(spacing: 2) {

                    // 📷 Smart camera
                    Button(action: isStreaming ? captureSDKPhoto : quickCapture) {
                        toolbarIcon("camera.fill",
                                    tint: isCapturing ? .orange : .primary,
                                    active: isCapturing)
                    }
                    .disabled(isCapturing)

                    // 🎬 Stream  (video family — visually matches camera.fill)
                    Button(action: isStreaming ? stopStream : startDiscoveryAndStream) {
                        ZStack(alignment: .topTrailing) {
                            if isConnecting {
                                // Show a spinner while connecting so the user knows it's working
                                ProgressView()
                                    .frame(width: 28, height: 28)
                            } else {
                                toolbarIcon(isStreaming ? "video.fill" : "video",
                                            tint: isStreaming ? .red : .secondary,
                                            active: isStreaming)
                            }
                            if isStreaming {
                                Circle()
                                    .fill(Color.red)
                                    .frame(width: 7, height: 7)
                                    .offset(x: 2, y: -2)
                            }
                        }
                    }
                    .disabled(isConnecting && !isStreaming)

                    // 🎤 Hey Max
                    Button(action: toggleHeyMax) {
                        toolbarIcon(speechManager.isListening ? "mic.fill" : "mic",
                                    tint: speechManager.isListening ? .green : .secondary,
                                    active: speechManager.isListening)
                            .symbolEffect(.pulse, isActive: speechManager.isListening)
                    }

                    // ↑ Send (spring-appears when typing)
                    if !textInput.isEmpty {
                        Button(action: sendTextInput) {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 28))
                                .foregroundStyle(Color.blue)
                        }
                        .transition(.scale.combined(with: .opacity))
                    }
                }
                .animation(.spring(duration: 0.2), value: textInput.isEmpty)
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, max((UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first?.windows.first?.safeAreaInsets.bottom ?? 0) - 4, 8))
            .background(.regularMaterial)
        }
    }

    /// Shared circular icon appearance for the toolbar buttons.
    private func toolbarIcon(_ symbol: String, tint: Color, active: Bool) -> some View {
        ZStack {
            Circle()
                .fill(active ? tint.opacity(0.12) : Color.clear)
                .frame(width: 36, height: 36)
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(tint)
        }
        .frame(width: 36, height: 36)
    }

    // MARK: - Setup controls (hidden in main UI — accessible via Settings)
    //   Kept for programmatic access; not rendered in the main view hierarchy.

    private var controlsView: some View {
        EmptyView()
    }

    // MARK: - Listening pill

    private var listeningPill: some View {
        VStack(spacing: 3) {
            HStack(spacing: 6) {
                Circle().fill(Color.green).frame(width: 7, height: 7)
                Text(speechManager.statusText).font(.caption.weight(.semibold))
            }
            if !speechManager.liveText.isEmpty {
                Text("\"\(speechManager.liveText)\"")
                    .font(.caption2).foregroundColor(.secondary).lineLimit(1).truncationMode(.head)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.regularMaterial).clipShape(Capsule())
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    }

    // MARK: - Photo ask sheet

    private var photoAskSheet: some View {
        NavigationStack {
            VStack(spacing: 14) {
                if let photo = capturedPhoto {
                    Image(uiImage: photo)
                        .resizable().aspectRatio(contentMode: .fit)
                        .frame(maxHeight: 220).cornerRadius(12)
                }

                TextField("What do you want to know?", text: $textInput, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(3)

                // Ask Max (AI vision analysis)
                Button(action: {
                    showPhotoAsk = false
                    sendPhotoQuestion()
                }) {
                    Label("Ask Max", systemImage: "sparkles")
                        .font(.headline).foregroundColor(.white)
                        .frame(maxWidth: .infinity).padding()
                        .background(textInput.isEmpty ? Color.gray : Color.blue)
                        .cornerRadius(14)
                }
                .disabled(textInput.isEmpty)

                // Divider with "or" label
                HStack {
                    Rectangle().frame(height: 0.5).foregroundStyle(Color(.separator))
                    Text("or").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8)
                    Rectangle().frame(height: 0.5).foregroundStyle(Color(.separator))
                }

                // Search Online — sends text as a web search (no image)
                Button(action: {
                    showPhotoAsk = false
                    let q = textInput.isEmpty ? "search about what I see" : textInput
                    textInput = ""
                    Task {
                        try? await AgentBrain.shared.respond(
                            to: "search \(q)", image: nil, debugMode: debugMode
                        )
                    }
                }) {
                    Label("Search Online", systemImage: "magnifyingglass")
                        .font(.headline)
                        .frame(maxWidth: .infinity).padding()
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(14)
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.blue.opacity(0.4)))
                }

                // Divider
                HStack {
                    Rectangle().frame(height: 0.5).foregroundStyle(Color(.separator))
                    Text("or").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8)
                    Rectangle().frame(height: 0.5).foregroundStyle(Color(.separator))
                }

                // Remember This — save photo with AI tags + location
                if let photo = capturedPhoto {
                    Button(action: {
                        showPhotoAsk = false
                        rememberPhoto(photo)
                    }) {
                        HStack {
                            if isSavingMemory {
                                ProgressView().tint(.white).scaleEffect(0.8)
                                Text("Saving memory…")
                            } else {
                                Label("Remember This", systemImage: "bookmark.fill")
                            }
                        }
                        .font(.headline).foregroundColor(.white)
                        .frame(maxWidth: .infinity).padding()
                        .background(isSavingMemory ? Color.gray : Color.orange)
                        .cornerRadius(14)
                    }
                    .disabled(isSavingMemory)
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Snapshot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showPhotoAsk = false }
                }
            }
        }
    }

    // MARK: - Settings sheet

    private var settingsSheet: some View {
        NavigationStack {
            Form {
                // ── 1. Setup (first-use, always visible at top) ─────────────
                Section {
                    Button(action: { showSettings = false; registerApp() }) {
                        HStack {
                            Label("Register with Meta App", systemImage: "link")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(.primary)

                    Button(action: { showSettings = false; requestCamera() }) {
                        HStack {
                            Label("Request Camera Access", systemImage: "camera")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(.primary)
                } header: { Text("Glasses Setup") } footer: {
                    Text("Run both once to pair your Ray-Ban Meta glasses and grant camera permission.")
                }

                // ── 2. AI Settings ──────────────────────────────────────────
                Section {
                    Picker("Provider", selection: $selectedProviderRaw) {
                        ForEach(AIProvider.allCases) { provider in
                            Text(provider.displayName).tag(provider.rawValue)
                        }
                    }
                    .onChange(of: selectedProviderRaw) { _, _ in
                        if selectedProviderRaw != AIProvider.gemini.rawValue &&
                            selectedProviderRaw != AIProvider.openAI.rawValue {
                            selectedProviderRaw = AIProvider.openAI.rawValue
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text(selectedProvider == .openAI ? "OpenAI API Key" : "Gemini API Key")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        SecureField(
                            selectedProvider == .openAI ? "sk-..." : "Enter Gemini API key",
                            text: selectedProvider == .openAI ? $openAIKeyInput : $geminiKeyInput
                        )
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(selectedProvider == .openAI ? "OpenAI Model" : "Gemini Model")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField(
                            "Model name",
                            text: selectedProvider == .openAI ? $openAIModel : $geminiModel
                        )
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Serper API Key (web search)").font(.caption).foregroundColor(.secondary)
                        SecureField("Enter key from serper.dev", text: $serperKey)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                } header: { Text("AI Settings") } footer: {
                    Text("Provider key is stored in iOS Keychain. OpenAI: platform.openai.com/api-keys · Gemini: aistudio.google.com/apikey · Serper: serper.dev")
                }

                // ── 3. Voice & Language ─────────────────────────────────────
                Section {
                    Picker("Speech Language", selection: $speechLocale) {
                        Text("English (US)").tag("en-US")
                        Text("English (UK)").tag("en-GB")
                        Text("Hebrew").tag("he-IL")
                        Text("Arabic").tag("ar-SA")
                        Text("Spanish").tag("es-ES")
                        Text("French").tag("fr-FR")
                        Text("German").tag("de-DE")
                        Text("Russian").tag("ru-RU")
                        Text("Portuguese").tag("pt-BR")
                        Text("Italian").tag("it-IT")
                        Text("Chinese (Simplified)").tag("zh-CN")
                        Text("Japanese").tag("ja-JP")
                    }
                    .onChange(of: speechLocale) { newLocale in
                        speechManager.speechLocale = newLocale
                    }
                } header: { Text("Voice & Language") } footer: {
                    Text("Sets the language for speech recognition and Max's voice responses. Restart Hey Max toggle after changing.")
                }

                // ── 4. Memory ───────────────────────────────────────────────
                Section("Memory") {
                    NavigationLink("View & Manage Memories") { MemoriesView() }
                    Button {
                        Task { await MemoryStore.shared.consolidateFacts() }
                    } label: {
                        Label("Clean Up Duplicate Facts", systemImage: "wand.and.sparkles")
                    }
                    Button(role: .destructive) {
                        confirmClearMemory = true
                    } label: {
                        Label("Clear All Memories", systemImage: "trash")
                    }
                    Button {
                        confirmResetSession = true
                    } label: {
                        Label("Reset Session History", systemImage: "arrow.counterclockwise")
                    }
                }
                .confirmationDialog(
                    "Clear All Memories?",
                    isPresented: $confirmClearMemory,
                    titleVisibility: .visible
                ) {
                    Button("Clear Everything", role: .destructive) { MemoryStore.shared.clear() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This permanently deletes all facts, episodes, and summaries Max has learned about you. This cannot be undone.")
                }
                .confirmationDialog(
                    "Reset Session History?",
                    isPresented: $confirmResetSession,
                    titleVisibility: .visible
                ) {
                    Button("Reset Session", role: .destructive) { AgentBrain.shared.clearSession() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("The current conversation context will be cleared. Long-term memories are kept.")
                }

                // ── 4. Learned Preferences ──────────────────────────────────
                Section("Learned Preferences") {
                    ForEach(Array(AgentBrain.shared.preferences), id: \.key) { key, value in
                        HStack { Text(key).foregroundColor(.secondary); Spacer(); Text(value) }
                    }
                    if AgentBrain.shared.preferences.isEmpty {
                        Text("Max learns your name, language preference, and detail level as you chat.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }

                // ── 5. Developer ────────────────────────────────────────────
                Section {
                    Toggle(isOn: $debugMode) {
                        Label("Debug Mode", systemImage: "ant.fill")
                    }
                    if debugMode {
                        Text("A collapsible card after each reply shows system prompt, memory context, tokens, and raw JSON. Remove before App Store release.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                } header: { Text("Developer") }

                // ── 6. How to use ───────────────────────────────────────────
                Section("How to use") {
                    Label("Tap 📷 to capture · 🎬 for live stream", systemImage: "camera")
                    Label("Say 'Hey Max' or tap 🎤 to talk", systemImage: "mic")
                    Label("Tap chips below answers to continue", systemImage: "bubble.left")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        persistAISettings()
                        showSettings = false
                    }
                }
            }
            .onAppear {
                loadAISettingsFromKeychain()
            }
        }
    }

    // MARK: - Stream management

    func registerApp() {
        statusMessage = "Opening Meta app…"
        Task {
            do { try await Wearables.shared.startRegistration() }
            catch { await MainActor.run { statusMessage = "Reg Error: \(error.localizedDescription)" } }
        }
    }

    func requestCamera() {
        statusMessage = "Requesting Camera Access…"
        Task {
            do {
                let s = try await Wearables.shared.requestPermission(.camera)
                await MainActor.run { statusMessage = s == .granted ? "Access Granted ✅" : "Access Denied ❌" }
            } catch {
                await MainActor.run { statusMessage = "Permission Error: \(error.localizedDescription)" }
            }
        }
    }

    func startDiscoveryAndStream() {
        // Prevent double-start: bail if already connecting or a session exists
        guard !isConnecting, !isStreaming, streamSession == nil else { return }
        // Avoid AVAudioSession contention between speech recognition and camera/stream setup.
        pauseListeningForCaptureIfNeeded()
        isConnecting  = true
        statusMessage = "Searching for glasses…"
        triggerLocalNetworkPrompt()

        devicesToken = Wearables.shared.addDevicesListener { [self] deviceIds in
            guard let deviceId = deviceIds.first else { return }
            Task { @MainActor in
                // Cancel listener immediately so it can't fire a second time
                self.devicesToken = nil
                // Guard again — two Tasks could queue up before the first runs
                guard self.streamSession == nil else {
                    self.isConnecting = false; return
                }
                self.cachedDeviceId = deviceId
                let name = Wearables.shared.deviceForIdentifier(deviceId)?.name ?? "Ray-Ban Meta"
                self.statusMessage = "Found \(name)…"
                self.setupStream(for: deviceId)
            }
        }
    }

    func setupStream(for deviceId: DeviceIdentifier) {
        // If a stale session exists, stop it cleanly before creating a new one.
        // Skipping this causes the native C++ callbacks to fire on a freed object → crash.
        if let old = streamSession {
            let captured = old
            Task { await captured.stop() }
            streamSession  = nil
            frameToken     = nil; stateToken    = nil
            errorToken     = nil; photoDataToken = nil
        }

        let config  = StreamSessionConfig(videoCodec: .raw, resolution: .low, frameRate: 24)
        let session = StreamSession(streamSessionConfig: config,
                                    deviceSelector: SpecificDeviceSelector(device: deviceId))
        streamSession = session
        isConnecting  = false   // discovery done; session object is now live

        frameToken = session.videoFramePublisher.listen { frame in
            if let img = frame.makeUIImage() {
                Task { @MainActor in self.currentFrame = img }
            }
        }

        photoDataToken = session.photoDataPublisher.listen { photoData in
            if let img = UIImage(data: photoData.data) {
                Task { @MainActor in
                    self.capturedPhoto = img
                    self.processCapturedImage(img)
                    self.isCapturing   = false
                    if self.suppressPhotoAskForAutoVision {
                        self.suppressPhotoAskForAutoVision = false
                    } else {
                        self.showPhotoAsk  = true
                    }
                }
            }
        }

        stateToken = session.statePublisher.listen { state in
            Task { @MainActor in
                switch state {
                case .waitingForDevice: self.statusMessage = "Waiting for glasses…"
                case .starting:         self.statusMessage = "Starting…"
                case .streaming:        self.statusMessage = "Streaming"; self.isStreaming = true
                case .paused:           self.statusMessage = "Paused"
                case .stopping:         self.statusMessage = "Stopping…"
                case .stopped:
                    self.statusMessage = "Stopped"
                    self.currentFrame  = nil
                    self.isStreaming   = false
                    self.isConnecting  = false
                }
            }
        }
        errorToken = session.errorPublisher.listen { err in
            Task { @MainActor in
                self.statusMessage = "Error: \(err)"
                self.currentFrame  = nil
                self.isStreaming   = false
                self.isConnecting  = false
            }
        }
        Task { await session.start() }
    }

    func stopStream() {
        let session = streamSession
        streamSession  = nil
        frameToken     = nil; stateToken    = nil
        errorToken     = nil; photoDataToken = nil
        currentFrame   = nil; isStreaming    = false
        isConnecting   = false
        statusMessage  = "Stream stopped"
        // Stop the native session after clearing all our Swift references,
        // so no callbacks fire back into now-nil tokens.
        if let s = session {
            Task { await s.stop() }
        }
    }

    // MARK: - Photo capture

    func captureSDKPhoto() {
        guard let session = streamSession else {
            capturedPhoto = currentFrame
            if capturedPhoto != nil {
                if let photo = capturedPhoto { processCapturedImage(photo) }
                if suppressPhotoAskForAutoVision {
                    suppressPhotoAskForAutoVision = false
                } else {
                    showPhotoAsk = true
                }
            }
            return
        }
        pauseListeningForCaptureIfNeeded()
        isCapturing = true
        let ok = session.capturePhoto(format: .jpeg)
        if !ok {
            capturedPhoto = currentFrame
            isCapturing   = false
            if capturedPhoto != nil {
                if let photo = capturedPhoto { processCapturedImage(photo) }
                if suppressPhotoAskForAutoVision {
                    suppressPhotoAskForAutoVision = false
                } else {
                    showPhotoAsk = true
                }
            }
        }
    }

    /// One-shot photo capture without needing a live stream.
    ///
    /// • Skips device discovery if we have a cached ID from a previous connection.
    /// • Attempts capturePhoto at .starting state — before full streaming, for speed.
    /// • Cancels automatically after 12 s with a clear message if glasses can't connect.
    func quickCapture() {
        guard !isCapturing else { return }
        pauseListeningForCaptureIfNeeded()
        isCapturing   = true
        statusMessage = "Connecting to glasses…"
        triggerLocalNetworkPrompt()

        // Hard timeout — gives the user useful feedback instead of endless spinner
        captureTimeoutTask?.cancel()
        captureTimeoutTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(12))
            guard self.isCapturing else { return }   // already succeeded
            self.abortQuickCapture(
                message: "Glasses not found. Make sure they're powered on and within range."
            )
        }

        if let deviceId = cachedDeviceId {
            startQuickSession(for: deviceId)
        } else {
            devicesToken = Wearables.shared.addDevicesListener { deviceIds in
                guard let deviceId = deviceIds.first else { return }
                Task { @MainActor in
                    self.cachedDeviceId = deviceId
                    self.devicesToken   = nil
                    self.startQuickSession(for: deviceId)
                }
            }
        }
    }

    /// Cleanly cancels an in-progress quick-capture (timeout or manual abort).
    private func abortQuickCapture(message: String) {
        captureTimeoutTask?.cancel()
        captureTimeoutTask = nil
        isCapturing        = false
        statusMessage      = message
        quickCaptureRequested = false
        cachedDeviceId     = nil   // clear so next attempt re-discovers
        devicesToken       = nil
        quickStateToken    = nil
        quickPhotoToken    = nil
        quickFrameToken    = nil
        Task { await quickSession?.stop() }
        quickSession       = nil
        resumeListeningAfterCaptureIfNeeded()
    }

    private func startQuickSession(for deviceId: DeviceIdentifier) {
        // frameRate: 1 minimises resource — we only need a single photo
        let config  = StreamSessionConfig(videoCodec: .raw, resolution: .low, frameRate: 1)
        let session = StreamSession(streamSessionConfig: config,
                                    deviceSelector: SpecificDeviceSelector(device: deviceId))
        quickSession = session
        quickCaptureRequested = false

        quickPhotoToken = session.photoDataPublisher.listen { photoData in
            if let img = UIImage(data: photoData.data) {
                Task { @MainActor in
                    // Photo arrived — cancel the timeout before updating state
                    self.captureTimeoutTask?.cancel()
                    self.captureTimeoutTask = nil
                    self.capturedPhoto   = img
                    self.processCapturedImage(img)
                    self.isCapturing     = false
                    self.statusMessage   = "Photo captured"
                    if self.suppressPhotoAskForAutoVision {
                        self.suppressPhotoAskForAutoVision = false
                    } else {
                        self.showPhotoAsk    = true
                    }
                    self.quickCaptureRequested = false
                    Task { await session.stop() }
                    self.quickSession    = nil
                    self.quickPhotoToken = nil
                    self.quickStateToken = nil
                    self.quickFrameToken = nil
                }
            }
        }

        // Fallback path: if capturePhoto succeeds but SDK never publishes photoData,
        // use the first available frame so voice queries still get visual context.
        quickFrameToken = session.videoFramePublisher.listen { frame in
            if let img = frame.makeUIImage() {
                Task { @MainActor in
                    guard self.isCapturing else { return }
                    self.captureTimeoutTask?.cancel()
                    self.captureTimeoutTask = nil
                    self.capturedPhoto = img
                    self.processCapturedImage(img)
                    self.isCapturing = false
                    self.statusMessage = "Frame captured"
                    if self.suppressPhotoAskForAutoVision {
                        self.suppressPhotoAskForAutoVision = false
                    } else {
                        self.showPhotoAsk = true
                    }
                    self.quickCaptureRequested = false
                    Task { await session.stop() }
                    self.quickSession = nil
                    self.quickPhotoToken = nil
                    self.quickStateToken = nil
                    self.quickFrameToken = nil
                }
            }
        }

        // Attempt capture at the earliest possible state (.starting is faster than .streaming)
        quickStateToken = session.statePublisher.listen { state in
            Task { @MainActor in
                if (state == .starting || state == .streaming) && !self.quickCaptureRequested {
                    self.quickCaptureRequested = true
                    let ok = session.capturePhoto(format: .jpeg)
                    if !ok {
                        self.quickCaptureRequested = false
                        self.statusMessage = "Photo capture failed — try again"
                    }
                }
                if state == .stopped && self.isCapturing {
                    // Session ended without delivering a photo
                    self.abortQuickCapture(message: "Ready to Connect")
                }
            }
        }

        statusMessage = "Starting camera…"
        Task { await session.start() }
    }

    // MARK: - Voice for captured photo

    func startVoiceForPhoto() {
        speechManager.onWakeWordQuery = { [self] query in
            speechManager.onWakeWordQuery = { q in handleQuery(q, image: nil) }
            handleQuery(query, image: capturedPhoto)
        }
        speechManager.activateDirectMode()
        speechManager.statusText = "Ask about this photo…"
    }

    // MARK: - Text & query handling

    func sendTextInput() {
        let q = textInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        textInput = ""
        isInputFocused = false
        // Force vision when a captured photo is visible — the user is asking about it.
        handleQuery(q, image: capturedPhoto, forceVision: capturedPhoto != nil)
    }

    func sendPhotoQuestion() {
        let q = textInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        textInput = ""
        // User tapped "Ask Max" directly on the captured photo sheet — always use vision.
        handleQuery(q, image: capturedPhoto, forceVision: true)
    }

    /// Delegates the "should we auto-capture?" decision to the AI service
    /// instead of relying on hardcoded phrase matching.
    private func shouldAutoAttachVisionImage(for query: String) async -> Bool {
        await AgentBrain.shared.shouldAutoCaptureImage(for: query)
    }

    /// Waits for capturedPhoto to change (used by auto-vision capture flow).
    @MainActor
    private func waitForCapturedPhotoChange(from previous: UIImage?, timeoutSeconds: Double) async -> UIImage? {
        let start = Date()
        while Date().timeIntervalSince(start) < timeoutSeconds {
            if let latest = capturedPhoto {
                if let previous {
                    if latest !== previous { return latest }
                } else {
                    return latest
                }
            }
            try? await Task.sleep(for: .milliseconds(120))
        }
        return nil
    }

    /// Ensures we have an image for "what do I see" style requests.
    /// - If stream is on: use live frame, or trigger SDK photo capture.
    /// - If stream is off: run one-shot quick capture.
    @MainActor
    private func autoCaptureImageForVisionQuery() async -> UIImage? {
        if let frame = currentFrame { return frame }
        let previous = capturedPhoto
        suppressPhotoAskForAutoVision = true
        if isStreaming {
            captureSDKPhoto()
            let image = await waitForCapturedPhotoChange(from: previous, timeoutSeconds: 3.5)
            if image == nil { suppressPhotoAskForAutoVision = false }
            return image
        } else {
            quickCapture()
            let image = await waitForCapturedPhotoChange(from: previous, timeoutSeconds: 13.0)
            if image == nil { suppressPhotoAskForAutoVision = false }
            return image
        }
    }

    func handleQuery(_ query: String, image: UIImage?, forceVision: Bool = false) {
        Task { @MainActor in
            // Pass whichever image is available — captured photo takes priority,
            // live frame is a fallback.
            var frameToUse = image ?? currentFrame
            var shouldForceVision = forceVision
            // Voice/text queries like "what do I see?" should auto-capture an image.
            let shouldAutoCapture = await shouldAutoAttachVisionImage(for: query)
            if frameToUse == nil && shouldAutoCapture {
                aiResponse = "Capturing image…"
                frameToUse = await autoCaptureImageForVisionQuery()
                if frameToUse != nil { shouldForceVision = true }
            }

            isAnalyzing = true
            aiResponse  = frameToUse != nil ? "Looking…" : "Thinking…"

            let dm = debugMode     // capture for background Task
            do {
                let response = try await AgentBrain.shared.respond(
                    to: query, image: frameToUse, debugMode: dm, forceVision: shouldForceVision
                )
                isAnalyzing = false
                aiResponse = ""
                speechManager.speak(response)
            } catch {
                let msg = error.localizedDescription
                isAnalyzing = false
                aiResponse = ""
                AgentBrain.shared.chatHistory.append(ChatMessage(role: .assistant, content: msg, timestamp: Date()))
                speechManager.speak(msg)
            }
        }
    }

    func toggleHeyMax() {
        if speechManager.isListening {
            resumeMicAfterCapture = false
            micAutoStartedByStream = false
            speechManager.stopContinuousWakeListening()
        } else {
            micAutoStartedByStream = false
            speechManager.onWakeWordQuery = { q in handleQuery(q, image: nil) }
            speechManager.startContinuousWakeListening(preferBluetoothHFP: true)
        }
    }

    func triggerLocalNetworkPrompt() {
        let c = NWConnection(host: "192.168.1.1", port: 80, using: .tcp)
        c.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { c.cancel() }
    }
}

// MARK: - Chat bubble

struct ChatBubbleView: View {
    let message:    ChatMessage
    var debugMode:  Bool = false
    let onFollowUp: (String) -> Void
    @State private var copied = false
    @State private var selectedMemory: VisualMemory? = nil

    var isUser: Bool { message.role == .user }

    var body: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
            // ── Message bubble ──────────────────────────────────────────────
            HStack(alignment: .bottom, spacing: 6) {
                if !isUser {
                    Image(systemName: "sparkles").font(.caption2).foregroundColor(.blue).padding(.bottom, 2)
                }
                Text(message.content)
                    .font(.subheadline)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(isUser ? Color.blue : Color(.secondarySystemBackground))
                    .foregroundColor(isUser ? .white : .primary)
                    .cornerRadius(16)
                    .contextMenu {
                        Button { copy(message.content) } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if !isUser {
                            Button { copy(message.content) } label: {
                                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                    .font(.system(size: 9, weight: .medium)).foregroundColor(.secondary).padding(4)
                            }
                            .offset(x: 2, y: 20)
                        }
                    }
                if isUser {
                    Image(systemName: "person.circle.fill").font(.caption).foregroundColor(.blue).padding(.bottom, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)

            // ── Visual memory thumbnails (assistant only) ─────────────────────
            if !isUser && !message.visualMemories.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(message.visualMemories) { mem in
                            VisualMemoryThumbView(memory: mem)
                                .onTapGesture { selectedMemory = mem }
                        }
                    }
                    .padding(.leading, 26)
                    .padding(.trailing, 4)
                }
            }

            // ── Search result cards (assistant only) ──────────────────────────
            if !isUser && !message.searchResults.isEmpty {
                SearchResultsListView(results: message.searchResults)
                    .padding(.leading, 26)
                    .padding(.trailing, 4)
            }

            // ── Follow-up chips ──────────────────────────────────────────────
            if !isUser && !message.followUps.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(message.followUps, id: \.self) { q in
                            Button { onFollowUp(q) } label: {
                                Text(q).font(.caption.weight(.medium)).foregroundColor(.blue)
                                    .padding(.horizontal, 10).padding(.vertical, 5)
                                    .background(Color.blue.opacity(0.1)).cornerRadius(12)
                                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.blue.opacity(0.25)))
                            }
                        }
                    }
                    .padding(.leading, 26)
                }
            }

            // ── Debug card (assistant only, debug mode on) ───────────────────
            if !isUser, debugMode, let dbg = message.debugInfo {
                DebugCardView(info: dbg)
                    .padding(.leading, 26)
            }
        }
        .sheet(item: $selectedMemory) { mem in
            MemoryQuickLookSheet(memory: mem)
        }
    }

    private func copy(_ text: String) {
        UIPasteboard.general.string = text
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }
}

// MARK: - Visual memory thumbnail (chat inline)

struct VisualMemoryThumbView: View {
    let memory: VisualMemory
    @State private var thumb: UIImage?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let img = thumb {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color(.tertiarySystemBackground)
                        .overlay(Image(systemName: "photo").foregroundStyle(.tertiary))
                }
            }
            .frame(width: 80, height: 80)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            // Mini label strip
            Text(memory.aiSummary)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .padding(.horizontal, 4).padding(.vertical, 2)
                .background(Color.black.opacity(0.55))
                .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10))
                .frame(width: 80, alignment: .leading)
        }
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.blue.opacity(0.3), lineWidth: 1))
        .onAppear { thumb = VisualMemoryStore.shared.loadImage(for: memory) }
    }
}

// MARK: - Memory quick-look sheet (tapped from chat)

struct MemoryQuickLookSheet: View {
    let memory: VisualMemory
    @State private var image: UIImage?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Photo
                    Group {
                        if let img = image {
                            Image(uiImage: img)
                                .resizable()
                                .scaledToFit()
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        } else {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color(.secondarySystemBackground))
                                .aspectRatio(4/3, contentMode: .fit)
                                .overlay(ProgressView())
                        }
                    }
                    .padding(.horizontal)

                    VStack(alignment: .leading, spacing: 12) {
                        // Title + metadata
                        VStack(alignment: .leading, spacing: 4) {
                            Text(memory.aiSummary)
                                .font(.title3.weight(.semibold))
                            HStack(spacing: 12) {
                                Label(memory.timestamp.formatted(date: .long, time: .shortened),
                                      systemImage: "clock")
                                if let loc = memory.locationName {
                                    Label(loc, systemImage: "location.fill")
                                }
                            }
                            .font(.caption).foregroundStyle(.secondary)
                        }

                        if !memory.aiDescription.isEmpty {
                            Text(memory.aiDescription)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        if !memory.aiObjects.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Label("Objects in scene", systemImage: "magnifyingglass")
                                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                ForEach(memory.aiObjects, id: \.self) { obj in
                                    HStack(alignment: .top, spacing: 6) {
                                        Image(systemName: "circle.fill")
                                            .font(.system(size: 4)).foregroundStyle(.secondary).padding(.top, 5)
                                        Text(obj).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }

                        if !memory.aiTags.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) {
                                    ForEach(memory.aiTags, id: \.self) { tag in
                                        Text("#\(tag)")
                                            .font(.caption.weight(.medium))
                                            .padding(.horizontal, 8).padding(.vertical, 4)
                                            .background(Color.blue.opacity(0.1))
                                            .foregroundStyle(.blue)
                                            .clipShape(Capsule())
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal)
                }
                .padding(.vertical)
            }
            .navigationTitle("Memory")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear { image = VisualMemoryStore.shared.loadImage(for: memory) }
    }
}

// MARK: - Search results list

struct SearchResultsListView: View {
    let results: [SerperResult]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").font(.caption2).foregroundStyle(.secondary)
                Text("Web Results").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            }
            .padding(.bottom, 2)

            ForEach(results) { result in
                SearchResultCardView(result: result)
            }
        }
    }
}

// MARK: - Single search result card

struct SearchResultCardView: View {
    let result: SerperResult
    @State private var thumbnail: UIImage?
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            if let url = URL(string: result.link) { openURL(url) }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                // Thumbnail (async loaded)
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(.tertiarySystemFill))
                        .frame(width: 56, height: 56)

                    if let img = thumbnail {
                        Image(uiImage: img)
                            .resizable().scaledToFill()
                            .frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        Image(systemName: "globe")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 56, height: 56)

                // Text stack
                VStack(alignment: .leading, spacing: 3) {
                    Text(result.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    if let snippet = result.snippet {
                        Text(snippet)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }

                    HStack(spacing: 4) {
                        Image(systemName: "link").font(.system(size: 9))
                        Text(result.sourceName)
                            .font(.caption2)
                        if let date = result.date {
                            Text("· \(date)").font(.caption2)
                        }
                    }
                    .foregroundStyle(Color.blue.opacity(0.8))
                }

                Spacer(minLength: 0)

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
            .padding(10)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color(.separator).opacity(0.5), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .task(id: result.id) {
            guard let urlStr = result.imageUrl, !urlStr.isEmpty else { return }
            thumbnail = await ThumbnailCache.shared.load(urlString: urlStr)
        }
    }
}

// MARK: - Debug card

struct DebugCardView: View {
    let info:    DebugInfo
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Collapsed header ─────────────────────────────────────────────
            Button { withAnimation(.spring(duration: 0.25)) { expanded.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "ant.fill")
                        .font(.caption2).foregroundColor(.orange)
                    Text("Debug")
                        .font(.caption2.weight(.semibold)).foregroundColor(.orange)
                    Text("·")
                        .font(.caption2).foregroundColor(.secondary)
                    Text("\(info.processingMs)ms")
                        .font(.caption2).foregroundColor(.secondary)
                    Text("·")
                        .font(.caption2).foregroundColor(.secondary)
                    Text("\(info.promptTokens + info.completionTokens) tok")
                        .font(.caption2).foregroundColor(.secondary)
                    if info.hasImage {
                        Image(systemName: "camera.fill")
                            .font(.caption2).foregroundColor(.orange)
                    }
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption2).foregroundColor(.secondary)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
            }
            .buttonStyle(.plain)

            // ── Expanded body ────────────────────────────────────────────────
            if expanded {
                Divider().background(Color.orange.opacity(0.3))
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        let provider = AIProvider.selected
                        let model = UserDefaults.standard.string(forKey: provider.modelDefaultsKey)?
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        let resolvedModel = (model?.isEmpty == false ? model! : provider.defaultModel)
                        debugRow("Model", "\(provider.displayName) · \(resolvedModel)\(info.hasImage ? " + Vision" : "")")
                        debugRow("Tokens", "\(info.promptTokens) in · \(info.completionTokens) out · \(info.promptTokens + info.completionTokens) total")
                        debugRow("Time", "\(info.processingMs) ms")
                        debugRow("Memory context",
                                 "\(info.factsCount) facts · \(info.episodesCount) episodes · \(info.summariesCount) summaries")

                        Divider().background(Color.orange.opacity(0.2))

                        debugSection("System prompt (\(info.systemPrompt.count) chars)",
                                     info.systemPrompt.prefix(600) + (info.systemPrompt.count > 600 ? "\n…[truncated]" : ""))

                        Divider().background(Color.orange.opacity(0.2))

                        debugSection("Raw JSON response", prettyJSON(info.rawResponse))
                    }
                    .padding(10)
                }
                .frame(maxHeight: 320)
            }
        }
        .background(Color.orange.opacity(0.08))
        .cornerRadius(10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.orange.opacity(0.3), lineWidth: 1))
    }

    private func debugRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Text("\(label):")
                .font(.system(.caption2, design: .monospaced).weight(.semibold))
                .foregroundColor(.orange)
                .fixedSize()
            Text(value)
                .font(.system(.caption2, design: .monospaced))
                .foregroundColor(.primary)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func debugSection(_ title: String, _ content: String.SubSequence) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(.caption2, design: .monospaced).weight(.semibold))
                .foregroundColor(.orange)
            Text(content)
                .font(.system(.caption2, design: .monospaced))
                .foregroundColor(.primary)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func debugSection(_ title: String, _ content: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(.caption2, design: .monospaced).weight(.semibold))
                .foregroundColor(.orange)
            Text(content)
                .font(.system(.caption2, design: .monospaced))
                .foregroundColor(.primary)
                .textSelection(.enabled)
        }
    }

    /// Pretty-print JSON if possible, otherwise return raw string.
    private func prettyJSON(_ raw: String) -> String {
        guard let data    = raw.data(using: .utf8),
              let obj     = try? JSONSerialization.jsonObject(with: data),
              let pretty  = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let str     = String(data: pretty, encoding: .utf8) else { return raw }
        return str
    }
}

// MARK: - Typing indicator

struct TypingIndicatorView: View {
    @State private var animating = false
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "sparkles").font(.caption2).foregroundColor(.blue)
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    Circle().fill(Color.secondary).frame(width: 6, height: 6)
                        .scaleEffect(animating ? 1.3 : 0.7)
                        .animation(.easeInOut(duration: 0.5).repeatForever().delay(Double(i) * 0.15), value: animating)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color(.secondarySystemBackground)).cornerRadius(16)
        }
        .onAppear { animating = true }
    }
}

// MARK: - Memories view

struct MemoriesView: View {
    @State private var memories       = MemoryStore.shared.all
    @State private var summaries      = MemoryStore.shared.allSummaries
    @State private var confirmClearAll = false

    var body: some View {
        List {
            // ── Summary chapters ─────────────────────────────────────────────
            if !summaries.isEmpty {
                Section("Memory Summaries (\(summaries.count) chapters)") {
                    ForEach(summaries.reversed()) { s in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(s.text).font(.subheadline).lineLimit(4)
                            HStack {
                                Text(s.timestamp, style: .relative)
                                    .font(.caption2).foregroundColor(.secondary)
                                Text("· \(s.episodeCount) conversations compressed")
                                    .font(.caption2).foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }

            // ── Facts ────────────────────────────────────────────────────────
            let facts = memories.filter { $0.tags.contains("fact") }
            if !facts.isEmpty {
                Section("Personal Facts (\(facts.count))") {
                    ForEach(facts.reversed()) { m in memoryRow(m) }
                }
            }

            // ── Episodes ─────────────────────────────────────────────────────
            let episodes = memories.filter { !$0.tags.contains("fact") }
            if !episodes.isEmpty {
                Section("Conversation Episodes (\(episodes.count))") {
                    ForEach(episodes.reversed()) { m in memoryRow(m) }
                }
            }

            // Footer: explain when summaries appear
            Section {
                // empty section used purely for its footer text
            } footer: {
                let epCount = memories.filter { !$0.tags.contains("fact") }.count
                if summaries.isEmpty && epCount > 0 {
                    Text("Conversation summaries appear after 50 episodes. You have \(epCount) so far — \(max(0, 50 - epCount)) more to go.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if summaries.isEmpty {
                    Text("Max learns from your conversations and compresses old ones into summaries as they grow.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if memories.isEmpty && summaries.isEmpty {
                ContentUnavailableView(
                    "No memories yet", systemImage: "brain",
                    description: Text("Max remembers your conversations as you chat.")
                )
            }
        }
        .navigationTitle("Memory (\(memories.count + summaries.count))")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .destructiveAction) {
                Button("Clear All", role: .destructive) {
                    confirmClearAll = true
                }
            }
        }
        .confirmationDialog(
            "Clear All Memories?",
            isPresented: $confirmClearAll,
            titleVisibility: .visible
        ) {
            Button("Clear Everything", role: .destructive) {
                MemoryStore.shared.clear()
                memories  = []
                summaries = []
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes all facts, episodes, and summaries. This cannot be undone.")
        }
    }

    private func memoryRow(_ m: Memory) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(m.text).font(.subheadline).lineLimit(3)
            HStack {
                Text(m.timestamp, style: .relative).font(.caption2).foregroundColor(.secondary)
                ForEach(m.tags, id: \.self) { tag in
                    Text(tag).font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.blue.opacity(0.1)).cornerRadius(6)
                }
            }
        }
        .swipeActions {
            Button(role: .destructive) {
                MemoryStore.shared.delete(id: m.id)
                memories = MemoryStore.shared.all
            } label: { Label("Delete", systemImage: "trash") }
        }
    }
}
