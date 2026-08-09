import SwiftUI

struct ChatHistoryRowView: View {
    let session: ChatSession

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(session.languagePair.first.displayName) ⇄ \(session.languagePair.second.displayName)")
                    .font(.subheadline.bold())
                Spacer()
                Text(session.startedAt, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let firstHeard = session.turns.first?.heardText {
                Text(firstHeard)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text("\(session.turns.count) exchange\(session.turns.count == 1 ? "" : "s")")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    List {
        ChatHistoryRowView(session: ChatSession(
            id: UUID(), startedAt: Date(), languagePair: LanguagePair(first: .init(identifier: "en"), second: .init(identifier: "de")),
            turns: [ConversationTurn(heardText: "Where is the train station?", heardLanguage: .init(identifier: "en"), translatedText: "Wo ist der Bahnhof?", translatedLanguage: .init(identifier: "de"))]
        ))
    }
}
