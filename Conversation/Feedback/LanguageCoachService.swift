import Foundation

/// Builds the coaching prompt for a turn and runs it through
/// `FeedbackModelManager`. This is the one place the LLM's persona/behavior
/// is defined.
enum LanguageCoachService {
    /// Session-level persona and output-format rules for the coach's
    /// `ChatSession` (see `FeedbackModelManager.generate(prompt:)`). The
    /// task is deliberately language-agnostic and detected implicitly from
    /// the input, not named explicitly — the few-shot examples below teach
    /// "correct it, same language, output only the correction" across
    /// several languages without ever naming one, so this doesn't need
    /// `turn.heardLanguage`/`translatedLanguage` at all (and doesn't go
    /// stale if the user switches their language pair mid-session, unlike
    /// an earlier version that named a language directly).
    static let systemInstructions = """
        You repeat back the phrase you are given, but corrected so it is \
        natural and grammatically correct. Reply in the same language. Output only the corrected phrase, \
        nothing else — no labels, no explanation.

        Example:
        Input: guten tag!
        Output: Guten Tag!

        Example:
        Input: Je suis allé au magasin hier.
        Output: Je suis allé au magasin hier.

        Example:
        Input: Yo tengo veinte años.
        Output: Tengo veinte años.

        Example:
        Input: 私は学生です、そして毎日勉強しています。
        Output: 私は学生で、毎日勉強しています。
        """

    /// Mirrors `systemInstructions`' few-shot examples exactly
    /// (`Input: ... \n Output: ...`) rather than a more verbose framing —
    /// for a model this small, matching the few-shot pattern's literal
    /// structure matters a lot for it actually generalizing the pattern.
    /// An earlier version here wrapped the phrase in explanatory sentences
    /// and ended with "Reply in `turn.translatedLanguage`" — that line
    /// directly contradicted `systemInstructions`' "Reply in the same
    /// language," and being the last thing before generation, is the most
    /// likely reason the model was translating instead of correcting. The
    /// correction is always in `turn.heardLanguage` (the same language
    /// spoken), never `translatedLanguage` — this is a same-language
    /// grammar fix, not a coaching note in the other language.
    private static func prompt(for turn: ConversationTurn) -> String {
        "Input: \(turn.heardText)\nOutput:"
    }

    /// Generates the corrected, same-language version of `turn.heardText`.
    /// Throws on any failure (model not bundled, generation error) —
    /// callers treat that as "no feedback this time," not a user-visible
    /// error; see `ConversationLoopController`'s pipeline hook.
    static func feedback(for turn: ConversationTurn) async throws -> String {
        let raw = try await FeedbackModelManager.shared.generate(prompt: prompt(for: turn))
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
