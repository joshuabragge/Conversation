import Foundation

/// One completed exchange, kept only for the live session's on-screen
/// scrollback — not persisted to disk. v1 is explicitly the conversation
/// loop only; session history/vocabulary logging is out of scope (see plan).
struct ConversationTurn: Identifiable, Equatable {
    let id = UUID()
    let heardText: String
    let heardLanguage: Locale.Language
    let translatedText: String
    let translatedLanguage: Locale.Language
}
