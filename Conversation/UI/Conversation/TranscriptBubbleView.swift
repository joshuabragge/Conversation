import SwiftUI

struct TranscriptBubbleView: View {
    let turn: ConversationTurn

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            bubble(text: turn.heardText, language: turn.heardLanguage, tint: .accentColor)
            bubble(text: turn.translatedText, language: turn.translatedLanguage, tint: .secondary)
        }
    }

    private func bubble(text: String, language: Locale.Language, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(language.displayName.uppercased())
                .font(.caption2.bold())
                .foregroundStyle(tint)
            Text(text)
                .font(.body)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }
}

#Preview {
    TranscriptBubbleView(turn: ConversationTurn(
        heardText: "Where is the train station?",
        heardLanguage: .init(identifier: "en"),
        translatedText: "Wo ist der Bahnhof?",
        translatedLanguage: .init(identifier: "de")
    ))
    .padding()
}
