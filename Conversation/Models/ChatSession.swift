import Foundation

/// One hands-free run (`ConversationLoopController.start()` to the next
/// `start()`) worth of turns, persisted via `ConversationHistoryStore` —
/// but only once it actually has at least one turn in it. Starting a
/// session and stopping it again without anyone saying anything isn't
/// worth cluttering history with.
struct ChatSession: Identifiable, Equatable, Codable {
    let id: UUID
    let startedAt: Date
    let languagePair: LanguagePair
    var turns: [ConversationTurn]

    /// Plain-text rendering for the "copy whole conversation" action —
    /// a header line (languages + when) followed by every turn.
    var formattedText: String {
        let header = "\(languagePair.first.displayName) \u{21C4} \(languagePair.second.displayName) — "
            + startedAt.formatted(date: .abbreviated, time: .shortened)
        guard !turns.isEmpty else { return header }
        return "\(header)\n\n\(turns.map(\.formattedText).joined(separator: "\n\n"))"
    }
}
