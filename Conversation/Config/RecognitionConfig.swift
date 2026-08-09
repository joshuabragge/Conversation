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
enum WhisperModelOption: String, CaseIterable, Identifiable {
    case tiny
    case base

    var id: String { rawValue }
    var modelName: String { rawValue }

    /// Folder name matching WhisperKit's HuggingFace repo layout
    /// (`argmaxinc/whisperkit-coreml`), for the one model bundled directly
    /// in the app instead of downloaded on first use — see
    /// `WhisperModelManager.bundledFolder`. `nil` means "no bundled copy,
    /// download as usual"; only `.tiny` is bundled (~75MB is a reasonable
    /// permanent app-size cost for zero-network language-ID out of the
    /// box, ~150MB for `.base` isn't, and it stays available as an
    /// optional download from Settings).
    var bundledResourceName: String? {
        switch self {
        case .tiny: return "openai_whisper-tiny"
        case .base: return nil
        }
    }

    var displayName: String {
        switch self {
        case .tiny: return "Tiny (~75MB, fastest)"
        case .base: return "Base (~150MB, likely more accurate)"
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
