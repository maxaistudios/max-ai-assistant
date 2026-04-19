import Foundation
import Combine
import Speech
import AVFoundation

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

    override init() {
        super.init()
        synth.delegate = self
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                guard self?.isListening == true else { return }
                self?.beginSession()
            }
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
            guard buf.frameLength > 0 else { return }
            self?.request?.append(buf)
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
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.isListening, !self.speakingTTS else { return }
            self.beginSession()
        }
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

    private func log(_ msg: String) { print("[SpeechManager] \(msg)") }
}
