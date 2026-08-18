import Foundation

/// One completed exchange. Lives in `ConversationLoopController.history` for
/// the live session's on-screen scrollback, and is also what gets persisted
/// to disk via `ChatSession`/`ConversationHistoryStore` once a session has
/// at least one of these — see `ConversationHistoryStore` for why v1's
/// original "in-memory only, cleared on restart" design changed.
struct ConversationTurn: Identifiable, Equatable, Codable {
    let id: UUID
    let heardText: String
    let heardLanguage: Locale.Language
    let translatedText: String
    let translatedLanguage: Locale.Language
    /// Short coaching note on `heardText`, filled in asynchronously by the
    /// feature-flagged local-LLM feedback coach (`FeedbackConfig.isEnabled`,
    /// `Conversation/Feedback/`) a moment after the turn is first appended
    /// — `nil` until then, and permanently `nil` if the feature is off or
    /// generation failed. The only `var` field on this otherwise-immutable
    /// struct, since it's the one populated after the turn already exists;
    /// see `ConversationLoopController`'s pipeline hook for the
    /// `history[idx] = ...` in-place replace this implies.
    var feedback: String?

    init(
        id: UUID = UUID(), heardText: String, heardLanguage: Locale.Language,
        translatedText: String, translatedLanguage: Locale.Language, feedback: String? = nil
    ) {
        self.id = id
        self.heardText = heardText
        self.heardLanguage = heardLanguage
        self.translatedText = translatedText
        self.translatedLanguage = translatedLanguage
        self.feedback = feedback
    }

    // Locale.Language isn't natively Codable in a stable way across OS
    // versions (same reasoning as LanguagePair), so persist just the
    // BCP-47-ish identifier strings.
    private enum CodingKeys: String, CodingKey {
        case id, heardText, heardLanguage, translatedText, translatedLanguage, feedback
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        heardText = try container.decode(String.self, forKey: .heardText)
        heardLanguage = Locale.Language(identifier: try container.decode(String.self, forKey: .heardLanguage))
        translatedText = try container.decode(String.self, forKey: .translatedText)
        translatedLanguage = Locale.Language(identifier: try container.decode(String.self, forKey: .translatedLanguage))
        // decodeIfPresent: turns persisted before this field existed still decode fine.
        feedback = try container.decodeIfPresent(String.self, forKey: .feedback)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(heardText, forKey: .heardText)
        try container.encode(heardLanguage.minimalIdentifier, forKey: .heardLanguage)
        try container.encode(translatedText, forKey: .translatedText)
        try container.encode(translatedLanguage.minimalIdentifier, forKey: .translatedLanguage)
        try container.encodeIfPresent(feedback, forKey: .feedback)
    }

    /// Plain-text rendering for clipboard export — used both for "copy
    /// whole conversation" and for copying a subset of selected turns.
    var formattedText: String {
        "in-[\(heardLanguage.minimalIdentifier.uppercased())] \(heardText) \n out-[\(translatedLanguage.minimalIdentifier.uppercased())] \(translatedText)"
    }
}
