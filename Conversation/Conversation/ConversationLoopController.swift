import Foundation

/// The central hands-free conversation state machine (see `TurnState`),
/// tying together every module built in M1–M6:
/// `MicrophoneInputManager` + `VADSegmenter` (continuous listening,
/// auto-segmented turns) → `LanguageIdentifier` (WhisperKit) →
/// `SpeechRecognizerWrapper` (on-device STT in the detected locale) →
/// `TranslationService` → `SpeechOutputService`, with `AudioSessionManager`
/// switching Listening/Speaking around the TTS step and `AudioCueService`
/// earcons marking the transitions.
///
/// `TranslationService` is owned at the app root and lives in the SwiftUI
/// environment (its hidden `TranslationSessionHost` view needs to stay
/// mounted for the session to survive) — since environment values aren't
/// available inside a view's `init()`, this controller accepts it via
/// `configure(translationService:)` from `.onAppear` instead of the
/// initializer.
@MainActor
final class ConversationLoopController: ObservableObject {
    @Published private(set) var state: TurnState = .idle {
        didSet { AppLog.info(.conversation, "state: \(oldValue) -> \(state)") }
    }
    @Published private(set) var heardText: String = ""
    @Published private(set) var heardLanguage: Locale.Language?
    @Published private(set) var translatedText: String = ""
    /// In-memory only, cleared each time a session starts — v1 is
    /// explicitly the live conversation loop, not a persisted history.
    @Published private(set) var history: [ConversationTurn] = []
    /// `nil` = auto-detect (default). Set by the UI's manual language chip.
    @Published var manualOverride: Locale.Language?

    let audioSession: AudioSessionManager
    private(set) var languagePair: LanguagePair
    private let mic = MicrophoneInputManager()
    private let vad = VADSegmenter()
    private let languageIdentifier = LanguageIdentifier()
    private let recognizer = SpeechRecognizerWrapper()
    /// Exposed (not `private`) so Settings can bind its voice/rate picker
    /// to the same instance actually used for playback.
    let speechOutput = SpeechOutputService()
    private var translationService: TranslationService?

    private var wasRunningBeforeInterruption = false
    /// VAD ignores buffers until this time — set whenever the mic engine
    /// (re)starts, to swallow a transient pop/settling artifact from the
    /// hardware re-engaging (and, without headphones, any residual TTS
    /// echo) instead of letting it register as a false utterance start.
    /// A real device log showed WhisperKit confidently "identifying" such
    /// a false trigger while Apple's STT correctly found no actual speech
    /// in it — the turn got rejected safely, but it still cost a wasted
    /// cycle and could eat the first syllable of what the user meant to say.
    private var vadGraceUntil: Date = .distantPast
    private let vadGracePeriod: TimeInterval = 0.4

    init(audioSession: AudioSessionManager, languagePair: LanguagePair) {
        self.audioSession = audioSession
        self.languagePair = languagePair

        vad.onUtteranceStart = { [weak self] in
            Task { @MainActor in self?.handleUtteranceStart() }
        }
        vad.onUtteranceEnd = { [weak self] in
            Task { @MainActor in self?.handleUtteranceEnd() }
        }
        audioSession.onHeadphonesDisconnected = { [weak self] in self?.handleHeadphonesDisconnected() }
        audioSession.onInterruptionBegan = { [weak self] in self?.handleInterruptionBegan() }
        audioSession.onInterruptionEnded = { [weak self] in self?.handleInterruptionEnded() }
    }

    func configure(translationService: TranslationService) {
        self.translationService = translationService
    }

    /// Changes the active pair — only takes effect on the next `start()`;
    /// call `stop()` first if a session is already running.
    func updateLanguagePair(_ pair: LanguagePair) {
        languagePair = pair
    }

    /// Takes effect immediately, even mid-session — unlike the language
    /// pair, there's no reason to require a restart for this one.
    func setVADSensitivity(_ preset: VADSensitivityPreset) {
        vad.updateTrailingSilenceDuration(preset.trailingSilenceDuration)
    }

    // MARK: - Lifecycle

    func start() {
        AppLog.info(.conversation, "start() called, languagePair=\(languagePair.first.minimalIdentifier)/\(languagePair.second.minimalIdentifier)")
        guard state == .idle else {
            AppLog.debug(.conversation, "start(): ignored, state was already \(state)")
            return
        }
        guard translationService != nil else {
            state = .error("Not ready yet — try again in a moment.")
            return
        }
        history = []
        heardText = ""
        translatedText = ""
        heardLanguage = nil
        vad.reset()
        do {
            try audioSession.activateListening()
            armVADGracePeriod()
            try mic.startEngine { [weak self] samples, duration in
                guard let self, Date() >= self.vadGraceUntil else { return }
                self.vad.process(samples: samples, duration: duration)
            }
            state = .listening
        } catch {
            AppLog.error(.conversation, "start(): failed: \(error.localizedDescription)")
            state = .error("Couldn't start listening: \(error.localizedDescription)")
        }
    }

    func stop() {
        AppLog.info(.conversation, "stop() called")
        mic.stopEngine()
        audioSession.deactivate()
        state = .idle
    }

    private func armVADGracePeriod() {
        vadGraceUntil = Date().addingTimeInterval(vadGracePeriod)
        AppLog.debug(.conversation, "armVADGracePeriod: ignoring VAD input until \(vadGracePeriod)s from now")
    }

    // MARK: - VAD-driven turn boundaries

    private func handleUtteranceStart() {
        guard state == .listening else {
            AppLog.debug(.conversation, "handleUtteranceStart: ignored, state was \(state)")
            return
        }
        state = .capturing
        mic.beginUtteranceFile()
    }

    private func handleUtteranceEnd() {
        guard state == .capturing else {
            AppLog.debug(.conversation, "handleUtteranceEnd: ignored, state was \(state)")
            return
        }
        guard let fileURL = mic.endUtteranceFile() else {
            AppLog.error(.conversation, "handleUtteranceEnd: no file captured, returning to listening")
            state = .listening
            return
        }
        AudioCueService.playProcessing()
        Task { await process(fileURL: fileURL) }
    }

    // MARK: - Interruptions

    private func handleHeadphonesDisconnected() {
        guard state != .idle else { return }
        AppLog.info(.conversation, "handleHeadphonesDisconnected: pausing")
        stop()
        state = .error("Headphones disconnected — reconnect and tap start to resume.")
    }

    private func handleInterruptionBegan() {
        wasRunningBeforeInterruption = state != .idle
        guard wasRunningBeforeInterruption else { return }
        AppLog.info(.conversation, "handleInterruptionBegan: pausing")
        stop()
        state = .error("Paused for a call or other audio — tap start to resume.")
    }

    private func handleInterruptionEnded() {
        // Deliberately not auto-resuming: `AVAudioSession`'s "should
        // resume" signal has enough edge cases (some interruptions don't
        // want automatic resumption) that surfacing a manual restart is
        // safer than guessing, especially unverified on real hardware.
        AppLog.info(.conversation, "handleInterruptionEnded: not auto-resuming, waiting for manual start()")
        wasRunningBeforeInterruption = false
    }

    /// Holds `.rejected` visible/audible for a moment before returning to
    /// `.listening` — two immediately-consecutive `@Published` writes with
    /// no suspension between them would very likely coalesce into just the
    /// final value from the UI's perspective, and "didn't catch that"
    /// deserves an actual beat over hands-free/eyes-free use.
    private func showRejectedThenResumeListening() async {
        state = .rejected
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        guard state == .rejected else { return } // don't clobber a newer state
        state = .listening
    }

    /// Same problem as `.rejected` above, but for real errors — the old
    /// `catch` block set `.error` and immediately overwrote it with
    /// `.listening` in the same synchronous scope, so any error caught
    /// here (a missing TTS voice, a thrown `activateSpeaking()`, etc.) was
    /// **never actually visible** — it looked identical to silent failure.
    /// That's very likely why "no audio, no error shown" was happening.
    private func showErrorThenResumeListening(_ message: String) async {
        state = .error(message)
        // A failure could have happened after `mic.stopEngine()` (see the
        // Speaking-phase comment in `process`) but before it was restarted
        // — restart unconditionally so `.listening` never lies about
        // whether the mic is actually capturing. `restartEngine()` is a
        // no-op if the engine was never stopped.
        try? audioSession.activateListening()
        armVADGracePeriod()
        try? mic.restartEngine()
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        guard case .error = state else { return } // don't clobber a newer state
        state = .listening
    }

    // MARK: - Turn pipeline

    private func process(fileURL: URL) async {
        AppLog.info(.conversation, "process: starting turn for \(fileURL.lastPathComponent), manualOverride=\(manualOverride?.minimalIdentifier ?? "none (auto)")")
        let turnStart = Date()
        defer {
            try? FileManager.default.removeItem(at: fileURL)
            AppLog.info(.conversation, "process: turn finished in \(Date().timeIntervalSince(turnStart))s")
        }
        guard let translationService else {
            state = .error("Not ready yet.")
            return
        }

        do {
            let spokenLanguage: Locale.Language
            if let manualOverride {
                AppLog.info(.conversation, "process: using manual override \(manualOverride.minimalIdentifier)")
                spokenLanguage = manualOverride
            } else {
                state = .identifying
                // Previously unguarded: a stuck WhisperKit model
                // download/load (first run needs network) left
                // "Identifying language…" showing forever with nothing to
                // catch it. 45s covers a slow first-time download; a
                // loaded model normally answers in well under a second.
                let idResult = try await withTimeout(seconds: RecognitionConfig.languageIdentificationTimeout) {
                    try await self.languageIdentifier.identify(
                        fileURL: fileURL, candidates: self.languagePair.languages
                    )
                }
                guard idResult.isConfident else {
                    AudioCueService.playRejected()
                    await showRejectedThenResumeListening()
                    return
                }
                spokenLanguage = idResult.language
            }
            heardLanguage = spokenLanguage

            state = .transcribing
            let locale = Locale(identifier: spokenLanguage.minimalIdentifier)
            guard let text = await recognizer.transcribe(fileURL: fileURL, locale: locale), !text.isEmpty else {
                AudioCueService.playRejected()
                await showRejectedThenResumeListening()
                return
            }
            heardText = text

            let targetLanguage = languagePair.other(than: spokenLanguage)
            state = .translating
            let translated = try await withTimeout(seconds: RecognitionConfig.translationTimeout) {
                try await translationService.translate(text, from: spokenLanguage, to: targetLanguage)
            }
            translatedText = translated
            history.append(ConversationTurn(
                heardText: text, heardLanguage: spokenLanguage,
                translatedText: translated, translatedLanguage: targetLanguage
            ))

            state = .speaking
            // Must fully release the input route before switching category
            // away from `.playAndRecord` — leaving the engine running here
            // produced a real on-device `OSStatus '!pri'`
            // (AVAudioSessionErrorInsufficientPriority) failure (see
            // MicrophoneInputManager's doc comment).
            AppLog.debug(.conversation, "process: stopping mic engine before Speaking phase")
            mic.stopEngine()
            try audioSession.activateSpeaking()
            try await speechOutput.speak(translated, language: targetLanguage)
            AudioCueService.playBackToListening()

            try audioSession.activateListening()
            vad.reset()
            armVADGracePeriod()
            AppLog.debug(.conversation, "process: restarting mic engine after Speaking phase")
            try mic.restartEngine()
            state = .listening
        } catch is TimeoutError {
            await showErrorThenResumeListening("Timed out — check your network connection for first-time setup, then try again.")
        } catch {
            await showErrorThenResumeListening(error.localizedDescription)
        }
    }
}
