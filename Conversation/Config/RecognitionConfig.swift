import Foundation

/// VAD sensitivity presets for Settings — mapped to a concrete trailing-
/// silence duration rather than exposing the raw seconds value in the UI.
enum VADSensitivityPreset: String, CaseIterable, Identifiable {
    case short, medium, long

    var id: String { rawValue }

    /// How long a pause has to last before a turn is considered finished.
    var trailingSilenceDuration: TimeInterval {
        switch self {
        case .short: return 1.5
        case .medium: return 2.0
        case .long: return 2.5
        }
    }

    var displayName: String {
        switch self {
        case .short: return "Short pause"
        case .medium: return "Medium pause"
        case .long: return "Long pause"
        }
    }
}

/// WhisperKit model options for language-ID, exposed in Settings as an
/// experiment knob — accuracy/size/speed tradeoff is unverified without
/// real-device A/B testing, which is the whole point of making it
/// user-switchable rather than picking one blind.
///
/// Deliberately **only** WhisperKit's multilingual variants (`tiny`
/// through `large-v3`) are listed here — WhisperKit also ships `.en`-suffixed
/// English-only variants (`tiny.en`, `base.en`, `small.en`, `medium.en`;
/// there's no `large.en`) that are meaningfully smaller/faster, but this
/// app's whole job is picking *which* of two chosen languages was spoken;
/// an English-only model can't identify non-English audio at all, so one
/// would silently break language-ID for any pair that isn't English-only.
/// Not a candidate to add even as an "advanced" option.
///
/// Sizes below are approximate (the actual CoreML package sizes on
/// `argmaxinc/whisperkit-coreml`) and, past `base`, untested in this app —
/// `medium`/`large-v2`/`large-v3` are multiple GB and were designed for
/// full transcription quality, not a single quick language-ID pass; they
/// may simply be too slow on a phone to be worth using here at all. Listed
/// anyway because the only way to actually know is real-device iteration,
/// same reasoning as every other knob in this file.
enum WhisperModelOption: String, CaseIterable, Identifiable {
    case tiny
    case base
    case small
    case medium
    case largev2
    case largev3

    var id: String { rawValue }

    /// WhisperKit's `download(variant:)` and its model-loading path both
    /// take this exact string — it's glob-matched against folder names in
    /// the `argmaxinc/whisperkit-coreml` HuggingFace repo (see
    /// `WhisperKit.download`), not just a display label, so it must match
    /// `ModelVariant.description` from WhisperKit's own source (`tiny`,
    /// `base`, `small`, `medium`, `large-v2`, `large-v3`).
    var modelName: String {
        switch self {
        case .tiny: return "tiny"
        case .base: return "base"
        case .small: return "small"
        case .medium: return "medium"
        case .largev2: return "large-v2"
        case .largev3: return "large-v3"
        }
    }

    /// Folder name matching WhisperKit's HuggingFace repo layout
    /// (`argmaxinc/whisperkit-coreml`), for the one model bundled directly
    /// in the app instead of downloaded on first use — see
    /// `WhisperModelManager.bundledFolder`. `nil` means "no bundled copy,
    /// download as usual"; only `.tiny` is bundled (~75MB is a reasonable
    /// permanent app-size cost for zero-network language-ID out of the
    /// box; every other option, including `.base`, stays an optional
    /// download from Settings).
    var bundledResourceName: String? {
        switch self {
        case .tiny: return "openai_whisper-tiny"
        default: return nil
        }
    }

    var displayName: String {
        switch self {
        case .tiny: return "Tiny (~75MB, fastest, bundled)"
        case .base: return "Base (~150MB, likely more accurate)"
        case .small: return "Small (~500MB, slower)"
        case .medium: return "Medium (~1.5GB, slower still, unverified for real-time use)"
        case .largev2: return "Large v2 (~3.1GB, likely too slow for a quick LID pass)"
        case .largev3: return "Large v3 (~3.1GB, likely too slow for a quick LID pass)"
        }
    }
}

/// Centralized, tunable constants for the recognition pipeline. Several are
/// UserDefaults-backed (not just `static let`) so Settings can expose them
/// as live experiment knobs — real bilingual speech has shown the tiny
/// WhisperKit model can be confidently wrong (not just uncertain) on short
/// ambiguous phrases, especially with its documented English bias, and
/// there's no substitute for letting real usage tune these rather than
/// guessing fixed values once.
enum RecognitionConfig {
    private static let rejectThresholdKey = "com.joshuabragge.Conversation.languageIDRejectThreshold"
    private static let modelKey = "com.joshuabragge.Conversation.whisperModel"
    private static let vadSensitivityKey = "com.joshuabragge.Conversation.vadSensitivity"
    private static let vadSpeechThresholdKey = "com.joshuabragge.Conversation.vadSpeechThreshold"
    private static let vadMinSpeechDurationKey = "com.joshuabragge.Conversation.vadMinSpeechDuration"

    /// Same key `SettingsView`'s pause-sensitivity picker uses via
    /// `@AppStorage` — exposed here too so `ConversationLoopController` can
    /// read the persisted preset at construction time (see
    /// `vadSpeechThreshold`'s doc comment for why that matters).
    static var vadSensitivity: VADSensitivityPreset {
        get { UserDefaults.standard.string(forKey: vadSensitivityKey).flatMap(VADSensitivityPreset.init) ?? .medium }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: vadSensitivityKey) }
    }

    /// Relative energy (see `VADSegmenter.Config.speechThreshold`, whose
    /// 0.18 default this mirrors) above which a buffer counts as "speech"
    /// and opens a turn. This is the direct lever for "a loud non-speech
    /// sound (traffic, wind gust, a dog bark, a door slam) gets picked up
    /// and sent through language-ID/transcription/translation" — raising
    /// it means only louder-relative-to-background sounds trigger a turn.
    /// The right value depends on the real environment (a quiet room vs.
    /// a windy walk), so this is an experiment knob, not a fixed constant.
    static var vadSpeechThreshold: Double {
        get { UserDefaults.standard.object(forKey: vadSpeechThresholdKey) as? Double ?? 0.18 }
        set { UserDefaults.standard.set(newValue, forKey: vadSpeechThresholdKey) }
    }

    /// How long a sound has to stay above `vadSpeechThreshold` before it's
    /// treated as an utterance start (see `VADSegmenter.Config.minSpeechDuration`,
    /// whose 0.15s default this mirrors). Raising it filters out brief loud
    /// transients — a clap, a door slam, a single car horn — that spike
    /// above the energy threshold but don't sustain the way speech does;
    /// it does nothing against a *continuous* loud noise (traffic, wind),
    /// which is what `vadSpeechThreshold` is for.
    static var vadMinSpeechDuration: Double {
        get { UserDefaults.standard.object(forKey: vadMinSpeechDurationKey) as? Double ?? 0.15 }
        set { UserDefaults.standard.set(newValue, forKey: vadMinSpeechDurationKey) }
    }

    /// Below this renormalized-across-the-two-candidates confidence, a
    /// language-ID result is treated as `rejected` rather than guessed.
    /// 0.5 is chance for a binary decision, so this needs real headroom
    /// above that to mean anything — 0.6 is a conservative starting point.
    /// Exposed in Settings since the right value depends on the model and
    /// real usage, not something to fix in code once.
    static var languageIDRejectThreshold: Double {
        get { UserDefaults.standard.object(forKey: rejectThresholdKey) as? Double ?? 0.6 }
        set { UserDefaults.standard.set(newValue, forKey: rejectThresholdKey) }
    }

    /// Below this **absolute** (not renormalized) log-probability for
    /// whichever candidate WhisperKit favors, its language-ID call is
    /// treated as too weak to trust alone, and gets cross-checked against
    /// the other candidate locale via Apple's own on-device STT (see
    /// `ConversationLoopController.crossCheckLanguage`). This exists
    /// because the *relative* confidence above can read as 1.0 simply
    /// because the other candidate never appeared in WhisperKit's output
    /// at all, even while the model is genuinely unsure of its own top
    /// pick — a real device log showed WhisperKit confidently (by the
    /// relative metric) saying "en" for spoken German, at raw log-probs
    /// of -0.78 and -0.36 (46%/70% absolute linear confidence — mediocre,
    /// not strong). -0.3 ≈ 74% linear probability.
    static let languageIDHighConfidenceLogProb: Double = -0.3

    /// Which WhisperKit model `LanguageIdentifier` loads. Changing this
    /// only takes effect the next time a fresh `LanguageIdentifier`
    /// instance loads its model (e.g. next app launch, or next full
    /// onboarding pass) — it does not hot-swap an already-loaded model.
    static var whisperModel: WhisperModelOption {
        get { UserDefaults.standard.string(forKey: modelKey).flatMap(WhisperModelOption.init) ?? .tiny }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: modelKey) }
    }

    /// How long `stop()`'s self-finalize fallback waits for the
    /// recognizer's own callback before finalizing from whatever's already
    /// been transcribed (see the M4 AirPods finding).
    static let transcriptionFallbackTimeout: TimeInterval = 5.0

    #if DEBUG
    private static let allowServerBasedRecognitionKey = "com.joshuabragge.Conversation.allowServerBasedRecognition"

    /// **Diagnostic only — DEBUG builds, off by default.** When true,
    /// `SpeechRecognizerWrapper.transcribe` drops
    /// `requiresOnDeviceRecognition`, letting `SFSpeechRecognizer` fall
    /// back to Apple's servers.
    ///
    /// Exists to settle one question the app's own logs can't answer:
    /// whether repeated empty transcripts for clearly-audible,
    /// correctly-identified speech are our audio's fault or the on-device
    /// recognition asset's. The comparison that motivated it — iOS's own
    /// keyboard dictation transcribes the same speech every time — was
    /// never a like-for-like test, because the keyboard is free to use
    /// Apple's servers and follows the user's selected dictation language,
    /// so it never ran the code path this app does.
    /// `supportsOnDeviceRecognition` returning `true` is *not* a guarantee
    /// that a locale's offline asset is actually present and usable, which
    /// is what this toggle tests. If transcripts start working with it on,
    /// the audio pipeline is fine and the missing piece is that asset
    /// (check Settings > General > Keyboard > Dictation Languages, and
    /// Language & Region).
    ///
    /// **Turning this on sends recorded speech to Apple's servers**,
    /// contradicting the app's entirely-on-device premise — which is
    /// exactly why it's `#if DEBUG`, defaults to `false` (`UserDefaults.
    /// bool(forKey:)` returns `false` when unset), and is labelled as a
    /// diagnostic in Settings rather than offered as a normal option. Not
    /// a candidate for shipping as a "fallback when on-device fails."
    static var allowServerBasedRecognition: Bool {
        get { UserDefaults.standard.bool(forKey: allowServerBasedRecognitionKey) }
        set { UserDefaults.standard.set(newValue, forKey: allowServerBasedRecognitionKey) }
    }
    #endif

    /// How long to wait on a `TranslationSession` call before treating it
    /// as stuck (see the M2 zero-size-host-view finding).
    static let translationTimeout: TimeInterval = 20.0

    /// How long to wait on WhisperKit's language-ID pass before treating
    /// it as stuck. Generous because the very first call on a device also
    /// covers downloading the tiny model (needs network) — without this,
    /// a stalled download or model load left "Identifying language…"
    /// showing forever with nothing to catch it.
    static let languageIdentificationTimeout: TimeInterval = 45.0

    /// How long to wait on speech synthesis + playback before treating it
    /// as stuck. General safety net against a hung `AVSpeechSynthesizer`
    /// call (the app is foreground-only now, see `SpeechOutputService`'s
    /// doc comment for why, but this timeout is cheap insurance regardless
    /// of cause) — without it, a turn could hang at `.speaking` forever,
    /// with the mic left off, ending the hands-free loop with no way to
    /// recover except restarting.
    static let speechOutputTimeout: TimeInterval = 15.0

    /// After this many consecutive rejected/low-confidence turns, hint at
    /// the manual language chip instead of continuing to guess silently —
    /// heavy tiny-model tuning is expected to take real iteration, so the
    /// fallback needs to be visible, not just theoretically available.
    static let consecutiveRejectsBeforeHint = 2
}
