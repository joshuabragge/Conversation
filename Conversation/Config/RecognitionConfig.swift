import Foundation

/// VAD sensitivity presets for Settings — mapped to a concrete trailing-
/// silence duration rather than exposing the raw seconds value in the UI.
enum VADSensitivityPreset: String, CaseIterable, Identifiable {
    case short, medium, long

    var id: String { rawValue }

    /// How long a pause has to last before a turn is considered finished.
    var trailingSilenceDuration: TimeInterval {
        switch self {
        case .short: return 0.6
        case .medium: return 0.9
        case .long: return 1.3
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

/// Centralized, tunable constants for the recognition pipeline — kept in
/// one place because they're expected to change as M6 tunes them against
/// real bilingual speech (not yet done: these are sensible starting
/// defaults, not measured values).
enum RecognitionConfig {
    /// Below this renormalized-across-the-two-candidates confidence, a
    /// language-ID result is treated as `rejected` rather than guessed.
    /// 0.5 is chance for a binary decision, so this needs real headroom
    /// above that to mean anything — 0.6 is a conservative starting point.
    static let languageIDRejectThreshold: Double = 0.6

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
}
