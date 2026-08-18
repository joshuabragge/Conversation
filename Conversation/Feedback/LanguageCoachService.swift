import Foundation

/// Builds the coaching prompt for a turn and runs it through
/// `FeedbackModelManager`. This is the one place the LLM's persona/behavior
/// is defined — see `systemInstructions`' doc comment for why the actual
/// language names live in the per-turn prompt instead of baked in here.
enum LanguageCoachService {
    /// Session-level persona and output-format rules for the coach's
    /// `ChatSession` (see `FeedbackModelManager.loadedSession`).
    /// Deliberately language-agnostic: `ChatSession.instructions` is fixed
    /// for the lifetime of the loaded session, but the app's language pair
    /// can change after that (`AppState.updateLanguagePair`, see
    /// `CLAUDE.md`) — baking specific language names in here would go
    /// stale the first time someone switches languages without relaunching.
    /// The turn-specific languages are folded into each call's prompt
    /// instead, via `prompt(for:)`.
    static let systemInstructions = """
    You are a supportive, concise language-learning coach helping someone \
    practice speaking a language aloud. For each phrase you're given, \
    reply with one short (1-2 sentence) piece of feedback:
    - If there's a grammar, word-choice, or naturalness issue, name it \
    briefly and give the more natural phrasing.
    - If the phrase was already natural and correct, give brief \
    encouragement and, optionally, one alternative way to say the same \
    thing.
    Do not translate the phrase. Do not repeat it back in full. Reply only \
    with the feedback itself, no preamble or labels. Be warm but brief — \
    this is spoken practice, not a lecture.
    """

    /// Feedback is delivered in `turn.translatedLanguage` — the "other"
    /// language of the pair — on the assumption that's the one the
    /// speaker actually reads comfortably; worth confirming against real
    /// usage once this is running rather than a settled design decision.
    private static func prompt(for turn: ConversationTurn) -> String {
        """
        The speaker is practicing \(turn.heardLanguage.displayName). \
        They just said, in \(turn.heardLanguage.displayName):
        "\(turn.heardText)"
        Reply in \(turn.translatedLanguage.displayName).
        """
    }

    /// Generates a short coaching note for `turn.heardText`. Throws on any
    /// failure (model not bundled, generation error) — callers treat that
    /// as "no feedback this time," not a user-visible error; see
    /// `ConversationLoopController`'s pipeline hook.
    static func feedback(for turn: ConversationTurn) async throws -> String {
        let raw = try await FeedbackModelManager.shared.generate(prompt: prompt(for: turn))
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
