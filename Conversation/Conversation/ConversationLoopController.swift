import Foundation
import NaturalLanguage
import UIKit

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
        didSet {
            AppLog.info(.conversation, "state: \(oldValue) -> \(state)")
            updateIdleTimer()
        }
    }
    @Published private(set) var heardText: String = ""
    @Published private(set) var heardLanguage: Locale.Language?
    @Published private(set) var translatedText: String = ""
    /// The current run's scrollback — cleared on every `start()`. Also
    /// mirrored to `ConversationHistoryStore` turn-by-turn via
    /// `persistCurrentSession()`, so clearing this in-memory copy on the
    /// next `start()` doesn't lose it; it just moves it into history.
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
    /// Consecutive rejected/uncertain turns — after
    /// `RecognitionConfig.consecutiveRejectsBeforeHint`, the rejection
    /// message starts pointing at the manual language chip instead of
    /// just saying "try again," since heavy tiny-model tuning means
    /// repeated misses are expected, not exceptional.
    private var consecutiveRejects = 0
    /// Identifies the current run for `ConversationHistoryStore` — reset on
    /// every `start()` so a fresh walk becomes its own saved session
    /// instead of appending to whatever was last recorded.
    private var currentSessionID = UUID()
    private var sessionStartedAt = Date()

    init(audioSession: AudioSessionManager, languagePair: LanguagePair) {
        self.audioSession = audioSession
        self.languagePair = languagePair

        vad.onUtteranceStart = { [weak self] in
            Task { @MainActor in self?.handleUtteranceStart() }
        }
        vad.onUtteranceEnd = { [weak self] in
            Task { @MainActor in self?.handleUtteranceEnd() }
        }
        // Apply whatever was already persisted in Settings, not just
        // `VADSegmenter.Config.default` — these three used to only take
        // effect via `.onChange` while Settings was open, so a value
        // saved in a previous session was silently ignored on the next
        // cold launch until the user revisited Settings and nudged a
        // slider. `vad` is constructed fresh with the struct defaults
        // above, so this has to run before `start()` can be called.
        vad.updateTrailingSilenceDuration(RecognitionConfig.vadSensitivity.trailingSilenceDuration)
        vad.updateSpeechThreshold(Float(RecognitionConfig.vadSpeechThreshold))
        vad.updateMinSpeechDuration(RecognitionConfig.vadMinSpeechDuration)
        audioSession.onHeadphonesDisconnected = { [weak self] in self?.handleHeadphonesDisconnected() }
        audioSession.onInterruptionBegan = { [weak self] in self?.handleInterruptionBegan() }
        audioSession.onInterruptionEnded = { [weak self] in self?.handleInterruptionEnded() }

        // Start warming the detection model the moment this controller
        // exists — i.e. as soon as `ConversationView` is created, well
        // before the user has picked up their headphones and tapped
        // Start. See `prewarmLanguageModel()`'s doc comment for why this
        // used to land on the first spoken turn instead.
        prewarmLanguageModel()
    }

    func configure(translationService: TranslationService) {
        self.translationService = translationService
    }

    /// Loads (downloading first if needed) and JIT-warms the currently
    /// configured WhisperKit model in the background, without blocking
    /// anything. Called once from `init` so a fresh app launch starts
    /// this immediately, and again from Settings whenever the model
    /// selection changes.
    ///
    /// Without this, the cost — a real network download for anything
    /// beyond the bundled `tiny`, plus CoreML load/compile either way —
    /// landed on the very first turn's "Identifying language…" step
    /// instead: a real device log showed a fresh "small" download only
    /// starting *after* the user had already spoken and `endUtteranceFile`
    /// fired, several seconds of silence before language-ID even began.
    /// Onboarding's `AssetCheckView` already does something similar, but
    /// that's a one-time, separate `LanguageIdentifier` instance scoped to
    /// that view — it never warms the instance this controller actually
    /// uses, and doesn't run again on a later launch or after switching
    /// models in Settings, which is the gap this closes.
    ///
    /// `identify(fileURL:candidates:)` still calls `loadedWhisperKit()`
    /// itself regardless of whether this finished (or even started) —
    /// this is purely a head start, not a requirement, and a failure here
    /// is silently retried there rather than surfaced as an error.
    func prewarmLanguageModel() {
        Task {
            do {
                try await languageIdentifier.prewarm()
            } catch {
                AppLog.error(.conversation, "prewarmLanguageModel: failed, will retry on first real use: \(error.localizedDescription)")
            }
        }
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

    /// Takes effect immediately, even mid-session. See
    /// `RecognitionConfig.vadSpeechThreshold`'s doc comment — this is the
    /// main lever for "loud non-speech noise keeps triggering a turn."
    func setVADSpeechThreshold(_ threshold: Double) {
        vad.updateSpeechThreshold(Float(threshold))
    }

    /// Takes effect immediately, even mid-session. See
    /// `RecognitionConfig.vadMinSpeechDuration`'s doc comment.
    func setVADMinSpeechDuration(_ duration: Double) {
        vad.updateMinSpeechDuration(duration)
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
        currentSessionID = UUID()
        sessionStartedAt = Date()
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

    /// Keeps the screen from auto-locking for as long as a hands-free
    /// session is running (any state but `.idle` — mid-turn processing and
    /// a visible `.rejected`/`.error` banner all still count, since the
    /// walk is still "in progress" from the user's perspective). This is
    /// the replacement for the old locked-screen operation: the app no
    /// longer declares `UIBackgroundModes: audio` (see `project.yml`)
    /// because `AVSpeechSynthesizer` going silent while backgrounded turned
    /// out to be an unresolved Apple platform bug, not something fixable
    /// here — so instead of trying to keep working with the screen off,
    /// the app just doesn't let the screen turn off on its own while it's
    /// actively doing something. Only suppresses the *automatic*
    /// idle-timeout lock — the side button still locks the phone
    /// immediately, same as any other app.
    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = state != .idle
    }

    /// Saves (or updates) the current run in `ConversationHistoryStore`,
    /// called after every completed turn rather than just once at `stop()`
    /// — see the store's doc comment for why (swiping the app away
    /// mid-walk is a normal way to end a session, not an edge case).
    private func persistCurrentSession() {
        ConversationHistoryStore.shared.upsert(ChatSession(
            id: currentSessionID, startedAt: sessionStartedAt,
            languagePair: languagePair, turns: history
        ))
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
        // Also fires when the app is backgrounded, not just for a real call
        // or other app's audio — the system automatically deactivates an
        // active session for an app that doesn't declare
        // `UIBackgroundModes: audio` (deliberate here, see project.yml), so
        // "went to the background" and "a call came in" both land here with
        // no way to tell them apart from the notification alone. Either
        // way, requiring a manual restart (not auto-resuming) is correct.
        state = .error("Paused — tap start to resume.")
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
        consecutiveRejects += 1
        let message = consecutiveRejects >= RecognitionConfig.consecutiveRejectsBeforeHint
            ? "Didn't catch that — try the manual language chip if this keeps happening."
            : "Didn't catch that — try again."
        AppLog.info(.conversation, "showRejectedThenResumeListening: consecutiveRejects=\(consecutiveRejects)")
        state = .rejected(message)
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        guard case .rejected = state else { return } // don't clobber a newer state
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

        // DEBUG-only capture diagnostics — see `Debug/CaptureRecord.swift`.
        // Declared before the `do` block (not inside it) so both the
        // success path and every `catch`/`guard`-return below can reach
        // them. `saveCapture` guards against firing twice for the same
        // turn (e.g. a successful translate followed by a `speak()`-phase
        // error would otherwise both try to record — only the first,
        // more meaningful one should stick).
        #if DEBUG
        var diagnosticLanguageID: CaptureLanguageIDInfo?
        var diagnosticAttempts: [CaptureTranscriptAttempt] = []
        var captureSaved = false
        func saveCapture(_ outcome: CaptureOutcome) {
            guard !captureSaved else { return }
            captureSaved = true
            CaptureStore.shared.record(
                sourceFileURL: fileURL, languagePair: languagePair, manualOverride: manualOverride,
                languageID: diagnosticLanguageID, transcriptAttempts: diagnosticAttempts, outcome: outcome
            )
        }
        #endif

        do {
            let spokenLanguage: Locale.Language
            let text: String

            if let manualOverride {
                AppLog.info(.conversation, "process: using manual override \(manualOverride.minimalIdentifier)")
                state = .transcribing
                let transcript = await recognizer.transcribe(fileURL: fileURL, locale: Locale(identifier: manualOverride.minimalIdentifier))
                #if DEBUG
                diagnosticAttempts.append(CaptureTranscriptAttempt(locale: manualOverride.minimalIdentifier, text: transcript))
                #endif
                guard let t = transcript, !t.isEmpty else {
                    AudioCueService.playRejected()
                    #if DEBUG
                    saveCapture(.rejected("manual override (\(manualOverride.minimalIdentifier)): empty transcript"))
                    #endif
                    await showRejectedThenResumeListening()
                    return
                }
                spokenLanguage = manualOverride
                text = t
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
                #if DEBUG
                diagnosticLanguageID = CaptureLanguageIDInfo(
                    pickedLanguage: idResult.language.minimalIdentifier, confidence: idResult.confidence,
                    rawLogProb: idResult.rawLogProb, needsCrossCheck: idResult.needsCrossCheck
                )
                #endif
                guard idResult.isConfident else {
                    AudioCueService.playRejected()
                    #if DEBUG
                    saveCapture(.rejected("language-ID confidence too low (\(idResult.confidence))"))
                    #endif
                    await showRejectedThenResumeListening()
                    return
                }

                state = .transcribing
                if idResult.needsCrossCheck {
                    // WhisperKit's relative confidence reads as high, but
                    // its absolute confidence in that pick is mediocre —
                    // a real device log showed this exact combination
                    // being confidently wrong (German misread as English).
                    // Double-check against Apple's own STT in the other
                    // candidate locale before committing.
                    let alternate = languagePair.other(than: idResult.language)
                    let crossCheckResult = await crossCheckLanguage(
                        fileURL: fileURL, primary: idResult.language, alternate: alternate
                    )
                    #if DEBUG
                    diagnosticAttempts.append(CaptureTranscriptAttempt(locale: idResult.language.minimalIdentifier, text: crossCheckResult.primaryText))
                    diagnosticAttempts.append(CaptureTranscriptAttempt(locale: alternate.minimalIdentifier, text: crossCheckResult.alternateText))
                    #endif
                    guard let crossChecked = crossCheckResult.winner else {
                        AudioCueService.playRejected()
                        #if DEBUG
                        saveCapture(.rejected("cross-check: empty transcript in both \(idResult.language.minimalIdentifier) and \(alternate.minimalIdentifier)"))
                        #endif
                        await showRejectedThenResumeListening()
                        return
                    }
                    spokenLanguage = crossChecked.language
                    text = crossChecked.text
                } else {
                    let primaryTranscript = await recognizer.transcribe(fileURL: fileURL, locale: Locale(identifier: idResult.language.minimalIdentifier))
                    #if DEBUG
                    diagnosticAttempts.append(CaptureTranscriptAttempt(locale: idResult.language.minimalIdentifier, text: primaryTranscript))
                    #endif
                    guard let t = primaryTranscript, !t.isEmpty else {
                        // WhisperKit was confident about the language
                        // (that's why we're in this branch, not the
                        // cross-check one above), but Apple's on-device
                        // STT still came back with an empty transcript for
                        // it — a real device log showed this happening for
                        // genuine speech (isFinal fired normally, no
                        // error, just ""), not only for a false VAD
                        // trigger.
                        //
                        // A previous version of this code retried
                        // transcription in the *other* candidate locale
                        // here instead of rejecting outright, on the
                        // theory that a correctly-identified language
                        // shouldn't still get rejected. That was the wrong
                        // trade: a real device log then showed WhisperKit
                        // confidently picking "de" with English entirely
                        // absent from its own candidate distribution
                        // (`en=missing`, i.e. as close to zero probability
                        // as the model expresses), German STT correctly
                        // coming back empty, and *English* STT — forced to
                        // transcribe German audio it was never a
                        // plausible candidate for — confidently producing
                        // "Khasan heist Tak Hota": real English dictionary
                        // words strung into a nonsense phrase. That then
                        // translated into equally nonsensical German with
                        // no error shown anywhere. Forced wrong-locale STT
                        // doesn't fail loudly like an empty transcript
                        // does; it hallucinates fluent-sounding garbage in
                        // its own language instead, so "we got *some* text
                        // back" isn't evidence the guess was right.
                        // Between an occasional honest "didn't catch
                        // that" and a silently wrong translation, the
                        // former is the safer failure mode — don't
                        // reintroduce an other-locale retry here. (The
                        // `needsCrossCheck` branch above is different: it
                        // only runs when WhisperKit's own confidence was
                        // already mediocre, so weighing two real
                        // candidates against each other via
                        // `languagePlausibility` makes sense there in a
                        // way it doesn't once WhisperKit has already all
                        // but ruled the other language out.)
                        AudioCueService.playRejected()
                        #if DEBUG
                        saveCapture(.rejected("empty transcript in \(idResult.language.minimalIdentifier) (confident LID — not retrying the other locale, see ConversationLoopController.process)"))
                        #endif
                        await showRejectedThenResumeListening()
                        return
                    }
                    spokenLanguage = idResult.language
                    text = t
                }
            }

            consecutiveRejects = 0
            heardLanguage = spokenLanguage
            heardText = text

            let targetLanguage = languagePair.other(than: spokenLanguage)
            state = .translating
            let translated = try await withTimeout(seconds: RecognitionConfig.translationTimeout) {
                try await translationService.translate(text, from: spokenLanguage, to: targetLanguage)
            }
            translatedText = translated
            #if DEBUG
            saveCapture(.accepted(
                spokenLanguage: spokenLanguage.minimalIdentifier, heardText: text,
                translatedLanguage: targetLanguage.minimalIdentifier, translatedText: translated
            ))
            #endif
            history.append(ConversationTurn(
                heardText: text, heardLanguage: spokenLanguage,
                translatedText: translated, translatedLanguage: targetLanguage
            ))
            persistCurrentSession()

            state = .speaking
            // Must fully release the input route before switching category
            // away from `.playAndRecord` — leaving the engine running here
            // produced a real on-device `OSStatus '!pri'`
            // (AVAudioSessionErrorInsufficientPriority) failure (see
            // MicrophoneInputManager's doc comment).
            AppLog.debug(.conversation, "process: stopping mic engine before Speaking phase")
            mic.stopEngine()
            try audioSession.activateSpeaking()
            do {
                try await withTimeout(seconds: RecognitionConfig.speechOutputTimeout) {
                    try await self.speechOutput.speak(translated, language: targetLanguage)
                }
            } catch is TimeoutError {
                // General safety net against a stuck speech-synthesis call
                // wedging the whole hands-free loop forever with the mic
                // left off — see SpeechOutputService's doc comment.
                // Recovers the loop even though this specific turn's audio
                // never played.
                AppLog.error(.conversation, "process: speak() timed out after \(RecognitionConfig.speechOutputTimeout)s")
                try? audioSession.activateListening()
                vad.reset()
                armVADGracePeriod()
                try? mic.restartEngine()
                await showErrorThenResumeListening("Couldn't speak the translation. Check the Debug Log.")
                return
            }

            try audioSession.activateListening()
            vad.reset()
            armVADGracePeriod()
            AppLog.debug(.conversation, "process: restarting mic engine after Speaking phase")
            try mic.restartEngine()
            // Play the "back to listening" cue only once the mic is
            // actually capturing again — it used to fire right after TTS
            // finished, while still in the Speaking config with the
            // engine stopped, which misrepresented when you could
            // actually start talking. The 0.4s VAD grace period already
            // in place absorbs this short tone the same way it absorbs
            // other post-restart artifacts, so this is a safe reordering.
            AudioCueService.playBackToListening()
            state = .listening
        } catch is TimeoutError {
            #if DEBUG
            saveCapture(.error("timed out"))
            #endif
            await showErrorThenResumeListening("Timed out — check your network connection for first-time setup, then try again.")
        } catch {
            #if DEBUG
            saveCapture(.error(error.localizedDescription))
            #endif
            await showErrorThenResumeListening(error.localizedDescription)
        }
    }

    /// Double-checks a WhisperKit pick that had low absolute confidence
    /// (`LanguageIdentificationResult.needsCrossCheck`) by transcribing
    /// the *same* file with Apple's on-device STT in both candidate
    /// locales — sequentially, not concurrently, since `SFSpeechRecognizer`
    /// only supports one active task at a time regardless — then using
    /// `NLLanguageRecognizer` to judge which transcript actually reads as
    /// plausible text in the language it was transcribed as. A
    /// forced-wrong-locale transcription tends to come out as recognizable
    /// nonsense in its own attempted language (see the "Hota de Sun shine"
    /// device log example), which this is meant to catch instead of
    /// blindly trusting WhisperKit's audio-only guess.
    ///
    /// This is a heuristic, not a guarantee — `NLLanguageRecognizer` is
    /// itself known to be less reliable on very short phrases. Treat this
    /// as one more (differently-biased) opinion, not a solved problem.
    ///
    /// Returns both raw transcripts alongside the winner (rather than just
    /// the winner) so callers building a `CaptureRecord` (DEBUG builds
    /// only, see `Debug/CaptureRecord.swift`) can show what each candidate
    /// locale actually produced, not just whichever one this method picked —
    /// plain `String?`s rather than the DEBUG-only `CaptureTranscriptAttempt`
    /// type, so this method itself doesn't need `#if DEBUG` gating.
    private func crossCheckLanguage(
        fileURL: URL, primary: Locale.Language, alternate: Locale.Language
    ) async -> (winner: (language: Locale.Language, text: String)?, primaryText: String?, alternateText: String?) {
        AppLog.info(.conversation, "crossCheckLanguage: verifying \(primary.minimalIdentifier) against \(alternate.minimalIdentifier)")
        let primaryText = await recognizer.transcribe(fileURL: fileURL, locale: Locale(identifier: primary.minimalIdentifier))
        let alternateText = await recognizer.transcribe(fileURL: fileURL, locale: Locale(identifier: alternate.minimalIdentifier))
        AppLog.info(.conversation, "crossCheckLanguage: \(primary.minimalIdentifier)=\"\(primaryText ?? "nil")\" \(alternate.minimalIdentifier)=\"\(alternateText ?? "nil")\"")

        let winner: (language: Locale.Language, text: String)?
        switch (primaryText, alternateText) {
        case (nil, nil):
            winner = nil
        case (let p?, nil):
            winner = (primary, p)
        case (nil, let a?):
            winner = (alternate, a)
        case (let p?, let a?):
            let candidates = [primary, alternate]
            let primaryScore = Self.languagePlausibility(of: p, expected: primary, among: candidates)
            let alternateScore = Self.languagePlausibility(of: a, expected: alternate, among: candidates)
            AppLog.info(.conversation, "crossCheckLanguage: plausibility \(primary.minimalIdentifier)=\(primaryScore) \(alternate.minimalIdentifier)=\(alternateScore)")
            winner = alternateScore > primaryScore ? (alternate, a) : (primary, p)
        }
        return (winner, primaryText, alternateText)
    }

    /// How much `text` reads like real `expected`-language text, per
    /// `NLLanguageRecognizer` constrained to just `among` (not its full
    /// language list, for the same reason `LanguageIdentifier` constrains
    /// WhisperKit's output to just the two candidates the user picked).
    nonisolated private static func languagePlausibility(
        of text: String, expected: Locale.Language, among candidates: [Locale.Language]
    ) -> Double {
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = candidates.map { NLLanguage($0.minimalIdentifier) }
        recognizer.processString(text)
        let hypotheses = recognizer.languageHypotheses(withMaximum: candidates.count)
        return hypotheses[NLLanguage(expected.minimalIdentifier)] ?? 0
    }
}
