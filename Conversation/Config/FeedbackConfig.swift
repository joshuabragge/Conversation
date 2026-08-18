import Foundation

/// Feature flag + tuning constants for the local-LLM speaking-feedback
/// coach (see `Conversation/Feedback/`) — an on-device Gemma 3 270M model
/// that silently annotates each turn's `heardText` with a short
/// grammar/naturalness note, entirely separate from the WhisperKit/Apple
/// STT/Translation pipeline that actually drives the conversation.
///
/// Same UserDefaults-backed, off-by-default shape as
/// `RecognitionConfig.allowServerBasedRecognition` — this is an unreleased
/// POC (roughly doubles the app's bundled-model footprint, on-device
/// latency/quality unverified) and shouldn't affect anyone who hasn't
/// explicitly opted in.
enum FeedbackConfig {
    private static let isEnabledKey = "com.joshuabragge.Conversation.aiFeedbackEnabled"

    /// `UserDefaults.bool(forKey:)` returns `false` when unset, so the
    /// default is off without needing a separate "has this ever been set"
    /// check.
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: isEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: isEnabledKey) }
    }

    /// How long to wait on a feedback generation call before giving up.
    /// Mirrors `RecognitionConfig.translationTimeout`'s role, but feedback
    /// is a background, non-blocking annotation (see
    /// `ConversationLoopController`'s pipeline hook) rather than something
    /// gating the live turn — a timeout here just stops an orphaned `Task`
    /// from running forever if MLX generation ever hangs, it doesn't risk
    /// stalling the listen→speak loop the way the STT/translation timeouts do.
    static let feedbackTimeout: TimeInterval = 20.0
}
