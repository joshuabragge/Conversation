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
    @Published private(set) var state: TurnState = .idle
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
        guard state == .idle else { return }
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
            try mic.startEngine { [weak self] samples, duration in
                self?.vad.process(samples: samples, duration: duration)
            }
            state = .listening
        } catch {
            state = .error("Couldn't start listening: \(error.localizedDescription)")
        }
    }

    func stop() {
        mic.stopEngine()
        audioSession.deactivate()
        state = .idle
    }

    // MARK: - VAD-driven turn boundaries

    private func handleUtteranceStart() {
        guard state == .listening else { return }
        state = .capturing
        mic.beginUtteranceFile()
    }

    private func handleUtteranceEnd() {
        guard state == .capturing else { return }
        guard let fileURL = mic.endUtteranceFile() else {
            state = .listening
            return
        }
        AudioCueService.playProcessing()
        Task { await process(fileURL: fileURL) }
    }

    // MARK: - Interruptions

    private func handleHeadphonesDisconnected() {
        guard state != .idle else { return }
        stop()
        state = .error("Headphones disconnected — reconnect and tap start to resume.")
    }

    private func handleInterruptionBegan() {
        wasRunningBeforeInterruption = state != .idle
        guard wasRunningBeforeInterruption else { return }
        stop()
        state = .error("Paused for a call or other audio — tap start to resume.")
    }

    private func handleInterruptionEnded() {
        // Deliberately not auto-resuming: `AVAudioSession`'s "should
        // resume" signal has enough edge cases (some interruptions don't
        // want automatic resumption) that surfacing a manual restart is
        // safer than guessing, especially unverified on real hardware.
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

    // MARK: - Turn pipeline

    private func process(fileURL: URL) async {
        defer { try? FileManager.default.removeItem(at: fileURL) }
        guard let translationService else {
            state = .error("Not ready yet.")
            return
        }

        do {
            let spokenLanguage: Locale.Language
            if let manualOverride {
                spokenLanguage = manualOverride
            } else {
                state = .identifying
                let idResult = try await languageIdentifier.identify(
                    fileURL: fileURL, candidates: languagePair.languages
                )
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
            try audioSession.activateSpeaking()
            await speechOutput.speak(translated, language: targetLanguage)
            AudioCueService.playBackToListening()

            try audioSession.activateListening()
            state = .listening
        } catch {
            state = .error(error.localizedDescription)
            try? audioSession.activateListening()
            state = .listening
        }
    }
}
