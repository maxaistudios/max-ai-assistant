import Foundation
import Combine
import Speech
import AVFoundation
import AudioToolbox

// MARK: - Wake word engine abstraction
//
// Keep this protocol small so a real on-device engine (e.g. Porcupine) can drop in
// later without touching SpeechManager flow/control logic.
protocol WakeWordEngine {
    /// Process one PCM frame (16-bit mono). Return true when wake word is detected.
    func process(frame: [Int16]) -> Bool
}

/// Placeholder implementation.
/// Always returns false for now; replace with Porcupine-backed implementation later.
final class PlaceholderWakeWordEngine: WakeWordEngine {
    func process(frame: [Int16]) -> Bool { false }
}

/// Two-stage wake word manager + TTS coordinator.
///
/// Core fix: a FRESH AVAudioEngine is created for every recognition session.
/// Re-using a single engine after TTS playback causes the inputNode to return
/// a 0-channel format (AVAudioBuffer mDataByteSize == 0) which produces
/// silence in the tap and "No speech detected" errors.
class SpeechManager: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {

    // MARK: - Published
    @Published var isListening = false
    @Published var statusText  = "Say 'Hey Max' to activate"
    @Published var liveText    = ""

    var onWakeWordQuery: ((String) -> Void)?

    // MARK: - State machine
    private enum Stage { case idle, awake }
    private var stage: Stage = .idle
    private var awakeTimeoutItem: DispatchWorkItem?
    private var pendingDirectMode = false   // set by activateDirectMode() before session exists

    // MARK: - Audio (engine is recreated fresh each session)

    /// The active speech locale identifier, stored in UserDefaults so it persists across launches.
    /// Changing this automatically restarts the recognition session if currently listening.
    var speechLocale: String {
        get { UserDefaults.standard.string(forKey: "speechLocale") ?? "en-US" }
        set {
            UserDefaults.standard.set(newValue, forKey: "speechLocale")
            // Restart session with the new locale if already listening
            if isListening {
                tearDown()
                task?.cancel(); task = nil
                beginSession()
            }
        }
    }

    /// Recognizer is computed so it always uses the current locale.
    private var recognizer: SFSpeechRecognizer? {
        SFSpeechRecognizer(locale: Locale(identifier: speechLocale))
    }

    private var engine:    AVAudioEngine?
    private var request:   SFSpeechAudioBufferRecognitionRequest?
    private var task:      SFSpeechRecognitionTask?
    private let synth      = AVSpeechSynthesizer()
    private var speakingTTS = false
    private var preferBluetoothHFPInput = false
    private let wakeWordEngine: WakeWordEngine = PlaceholderWakeWordEngine()
    private var continuousListeningRequested = false
    private var resumeWorkItem: DispatchWorkItem?
    private var restartWorkItem: DispatchWorkItem?

    override init() {
        super.init()
        synth.delegate = self
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioSessionInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Public API

    func startListening() {
        guard !isListening else { return }   // already on — ignore duplicate calls
        isListening = true                   // set early so rapid taps don't race
        log("Requesting speech auth…")
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                self?.log("Auth: \(status.rawValue)")
                guard status == .authorized else {
                    self?.isListening = false
                    self?.statusText = "Speech permission denied — enable in Settings"
                    return
                }
                self?.stage = .idle
                self?.beginSession()
            }
        }
    }

    /// Starts continuous wake listening and prefers the glasses microphone route.
    /// Use this for connected Ray-Ban Meta stream sessions.
    func startContinuousWakeListening(preferBluetoothHFP: Bool = true) {
        continuousListeningRequested = true
        preferBluetoothHFPInput = preferBluetoothHFP
        if isListening {
            // Already active: do not restart on every trigger (route-change storms).
            // Restarting repeatedly causes AVAudioEngine start failures.
            return
        }
        startListening()
    }

    /// Stops the continuous wake-listening pipeline.
    func stopContinuousWakeListening() {
        continuousListeningRequested = false
        resumeWorkItem?.cancel()
        resumeWorkItem = nil
        restartWorkItem?.cancel()
        restartWorkItem = nil
        stopListening()
    }

    var isContinuousWakeRequested: Bool { continuousListeningRequested }

    /// Temporarily pause listening without clearing the user's "mic on" intent.
    /// Used during capture flows that need an audio session handoff.
    func pauseListeningTemporarily() {
        guard isListening else { return }
        tearDown()
        task?.cancel(); task = nil
        isListening = false
        liveText = ""
    }

    /// Resume listening only if the user previously enabled continuous wake mode.
    func resumeContinuousWakeListeningIfRequested() {
        guard continuousListeningRequested, !isListening else { return }
        startContinuousWakeListening(preferBluetoothHFP: preferBluetoothHFPInput)
    }

    /// Skip the wake word and immediately enter "listening for a question" mode.
    /// Used by the photo Voice button so the next utterance goes straight to a query.
    func activateDirectMode() {
        if isListening {
            becomeAwake()
        } else {
            pendingDirectMode = true
            startListening()
        }
    }

    func stopListening() {
        log("stopListening")
        isListening       = false
        speakingTTS       = false
        pendingDirectMode = false
        awakeTimeoutItem?.cancel()
        tearDown()
        task?.cancel(); task = nil
        stage      = .idle
        statusText = "Hey Max is off"
        liveText   = ""
    }

    /// Speak text; pauses the mic while TTS is playing so it doesn't hear itself.
    func speak(_ text: String) {
        log("TTS: \(text.prefix(80))")
        speakingTTS = true
        tearDown()              // stop mic, discard old engine
        task?.cancel(); task = nil
        configureAudioSessionForTTS()

        let u = AVSpeechUtterance(string: text)
        // Use a voice matching the selected speech locale; fall back to en-US
        u.voice  = AVSpeechSynthesisVoice(language: speechLocale) ??
                   AVSpeechSynthesisVoice(language: "en-US")
        u.rate   = 0.50
        u.volume = 1.0
        synth.speak(u)
    }

    // MARK: - AVSpeechSynthesizerDelegate

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        log("TTS finished")
        speakingTTS = false
        guard isListening else { return }
        // Give audio routing 1.2 s to fully hand back to recording.
        // Shorter delays cause the 0-byte buffer issue.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.beginSession()
        }
    }

    // MARK: - Session loop

    private func beginSession() {
        guard isListening, !speakingTTS else { return }
        // Avoid duplicate concurrent start attempts during route-change storms.
        if engine?.isRunning == true { return }
        do {
            try startSession()
            // If activateDirectMode() was called before the session existed, enter awake now
            if pendingDirectMode {
                pendingDirectMode = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    self?.becomeAwake()
                }
            }
        } catch {
            log("Session error: \(error.localizedDescription)")
            scheduleRestart(after: 2.5)
        }
    }

    private func startSession() throws {
        // 1. Tear down any previous engine + request
        tearDown()
        task?.cancel(); task = nil

        // 2. Reset AVAudioSession: deactivate → reconfigure → activate
        //    This is the key step that clears any post-TTS routing locks.
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
        try audioSession.setCategory(
            .playAndRecord, mode: .default,
            options: [.duckOthers, .defaultToSpeaker, .allowBluetooth]
        )
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        configurePreferredInput(audioSession)

        guard audioSession.isInputAvailable else {
            throw NSError(domain: "SpeechManager", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No microphone available"])
        }

        // 3. Fresh engine — avoids stale input-node format from previous session
        let fresh = AVAudioEngine()
        engine    = fresh

        // 4. Verify input format has channels (will be 0 if session isn't ready)
        let inputNode = fresh.inputNode
        let fmt       = inputNode.outputFormat(forBus: 0)
        guard fmt.channelCount > 0 else {
            engine = nil
            throw NSError(domain: "SpeechManager", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Audio input format has 0 channels — retry later"])
        }

        // 5. Recognition request
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.taskHint = .dictation
        self.request = req

        // 6. Install tap on FRESH engine (no stale tap)
        //    Skip zero-length buffers — they produce AVAudioBuffer mDataByteSize == 0 warnings
        //    and feed empty audio to the recogniser, causing spurious "No speech" restarts.
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buf, _ in
            guard let self, buf.frameLength > 0 else { return }
            self.processWakeWordPCM(buf)
            self.request?.append(buf)
        }

        fresh.prepare()
        try fresh.start()

        isListening = true
        updateStatusForStage()

        task = recognizer?.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async { self?.handleResult(result, error: error) }
        }
        log("Session started (stage: \(stage), channels: \(fmt.channelCount))")
    }

    // MARK: - Result handling (always on main thread)

    private func handleResult(_ result: SFSpeechRecognitionResult?, error: Error?) {
        if let result {
            let raw = result.bestTranscription.formattedString
            let t   = raw.lowercased()
            liveText = raw

            switch stage {
            case .idle:
                if t.contains("hey max") {
                    log("Wake word: \"\(t)\"")
                    becomeAwake()
                    if result.isFinal {
                        let q = queryAfterWakeWord(in: t)
                        if !q.isEmpty { fireQuery(q); return }
                    }
                }
            case .awake:
                if result.isFinal {
                    var q = t.trimmingCharacters(in: .whitespacesAndNewlines)
                    if q.contains("hey max") { q = queryAfterWakeWord(in: q) }
                    if !q.isEmpty { fireQuery(q) } else { resetToIdle() }
                    return
                }
            }

            if result.isFinal { scheduleRestart() }
        }

        if let error {
            let desc = (error as NSError).localizedDescription
            let isCancelled = desc.lowercased().contains("canceled") || desc.contains("1110")
            // iOS can cancel recognition while we're in .awake (especially across
            // route/background transitions). If we already heard text, salvage it.
            if isCancelled, stage == .awake {
                let q = queryAfterWakeWord(in: liveText.lowercased())
                if !q.isEmpty {
                    fireQuery(q)
                    return
                }
                // No usable query captured — return to idle before restart.
                stage = .idle
                updateStatusForStage()
            }
            // "No speech detected" is expected when we manually stop the request — not a real error
            if !desc.contains("No speech") && !desc.contains("1110") {
                log("Recognition error: \(desc)")
            }
            scheduleRestart()
        }
    }

    // MARK: - State transitions

    private func becomeAwake() {
        stage      = .awake
        statusText = "Yes? I'm listening…"
        liveText   = ""
        playWakeDetectedSound()
        log("Stage → awake")

        awakeTimeoutItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard self?.stage == .awake else { return }
            self?.log("Awake timeout — back to idle")
            self?.resetToIdle()
        }
        awakeTimeoutItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: item)
    }

    private func fireQuery(_ query: String) {
        log("Firing query: \"\(query)\"")
        awakeTimeoutItem?.cancel()
        stage      = .idle
        statusText = "Processing…"
        playProcessingStartedSound()
        onWakeWordQuery?(query)
    }

    private func resetToIdle() {
        stage    = .idle
        liveText = ""
        updateStatusForStage()
        scheduleRestart()
    }

    private func updateStatusForStage() {
        statusText = stage == .awake ? "Yes? I'm listening…" : "Listening for 'Hey Max'…"
    }

    private func scheduleRestart(after delay: Double = 0.4) {
        tearDown()
        restartWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.isListening, !self.speakingTTS else { return }
            self.beginSession()
        }
        restartWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    // MARK: - Teardown (discards the engine; next session gets a fresh one)

    private func tearDown() {
        if let e = engine {
            if e.isRunning { e.stop() }
            e.inputNode.removeTap(onBus: 0)
            engine = nil
        }
        request?.endAudio()
        request = nil
    }

    // MARK: - Helpers

    private func queryAfterWakeWord(in text: String) -> String {
        (text.components(separatedBy: "hey max").last ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet.punctuationCharacters)
            .trimmingCharacters(in: .whitespaces)
    }

    private func configurePreferredInput(_ audioSession: AVAudioSession) {
        guard preferBluetoothHFPInput else { return }
        let inputs = audioSession.availableInputs ?? []
        if let hfp = inputs.first(where: { $0.portType == .bluetoothHFP }) {
            do {
                try audioSession.setPreferredInput(hfp)
                log("Preferred input set: \(hfp.portName) [bluetoothHFP]")
            } catch {
                log("Failed to set bluetoothHFP input: \(error.localizedDescription)")
            }
        } else {
            log("bluetoothHFP input not available; using default route")
        }
    }

    private func configureAudioSessionForTTS() {
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
        try? audioSession.setCategory(
            .playback,
            mode: .default,
            options: [.duckOthers]
        )
        try? audioSession.setActive(true, options: .notifyOthersOnDeactivation)
    }

    @objc private func handleAudioSessionInterruption(_ note: Notification) {
        guard continuousListeningRequested else { return }
        guard let info = note.userInfo,
              let rawType = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
        if type == .ended {
            scheduleResumeIfNeeded(delay: 0.5)
        }
    }

    @objc private func handleAudioRouteChange(_ note: Notification) {
        guard continuousListeningRequested else { return }
        // Re-arm after route switches (BT reconnect, background transitions), but debounce
        // aggressively to avoid restart loops while the route is still churning.
        scheduleResumeIfNeeded(delay: 1.0)
    }

    private func scheduleResumeIfNeeded(delay: TimeInterval) {
        guard continuousListeningRequested, !isListening, !speakingTTS else { return }
        resumeWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.resumeContinuousWakeListeningIfRequested()
        }
        resumeWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Convert AVAudioPCMBuffer to Int16 mono frames and feed the local wake-word engine.
    /// Detection currently uses a placeholder engine; hook Porcupine here later.
    private func processWakeWordPCM(_ buffer: AVAudioPCMBuffer) {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }

        var pcm: [Int16] = []
        pcm.reserveCapacity(frameCount)

        // Common iOS capture format: float32
        if let channels = buffer.floatChannelData {
            let c0 = channels[0]
            for i in 0..<frameCount {
                let clamped = max(-1.0, min(1.0, c0[i]))
                pcm.append(Int16(clamped * Float(Int16.max)))
            }
        } else if let channels = buffer.int16ChannelData {
            // If the hardware already gives int16, forward directly.
            let c0 = channels[0]
            for i in 0..<frameCount { pcm.append(c0[i]) }
        } else {
            return
        }

        guard wakeWordEngine.process(frame: pcm) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.stage == .idle else { return }
            self.log("Wake word detected by local engine")
            self.becomeAwake()
        }
    }

    private func playWakeDetectedSound() {
        AudioServicesPlaySystemSound(1113) // short "ack" tone
    }

    private func playProcessingStartedSound() {
        AudioServicesPlaySystemSound(1103) // subtle click/tock
    }

    private func log(_ msg: String) { print("[SpeechManager] \(msg)") }
}
