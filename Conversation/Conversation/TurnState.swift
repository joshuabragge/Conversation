import Foundation

/// The conversation loop's state machine, per the plan's turn diagram:
/// `idle → listening → capturing → identifying → transcribing →
/// translating → speaking → back to listening`, with `rejected` and
/// `error` as named sub-states rather than crashes.
enum TurnState: Equatable {
    case idle
    case listening
    case capturing
    case identifying
    case transcribing
    case translating
    case speaking
    /// Carries a message so `ConversationLoopController` can hint at the
    /// manual language chip after repeated rejections, instead of always
    /// showing the same generic text (see `RecognitionConfig.consecutiveRejectsBeforeHint`).
    case rejected(String)
    case error(String)

    /// Short, user-facing status text for the conversation screen.
    var statusDescription: String? {
        switch self {
        case .idle: return nil
        case .listening: return "Listening…"
        case .capturing: return "Capturing…"
        case .identifying: return "Identifying language…"
        case .transcribing: return "Transcribing…"
        case .translating: return "Translating…"
        case .speaking: return "Speaking…"
        case .rejected(let message): return message
        case .error(let message): return message
        }
    }
}
