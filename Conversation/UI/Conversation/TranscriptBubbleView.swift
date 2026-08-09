import SwiftUI

struct TranscriptBubbleView: View {
    let turn: ConversationTurn
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            bubbleInput(text: turn.heardText, language: turn.heardLanguage, tint: .accentColor)
            Divider()
            bubbleTranslated(text: turn.translatedText, language: turn.translatedLanguage, tint: .secondary)
        }
    }
    
    private func bubbleInput(text: String, language: Locale.Language, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(language.displayName.uppercased())
                .font(.caption2.bold())
                .foregroundStyle(tint)
            Text(text)
                .font(.body)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(in: RoundedRectangle(cornerRadius: 10))
    }
    private func bubbleTranslated(text: String, language: Locale.Language, tint: Color) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(language.displayName.uppercased())
                .font(.caption2.bold())
                .foregroundStyle(tint)
            Text(text)
                .font(.body)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .background( in: RoundedRectangle(cornerRadius: 10))
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
    TranscriptBubbleView(turn: ConversationTurn(
        heardText: "How are you today?",
        heardLanguage: .init(identifier: "en"),
        translatedText: "Wie gehts?",
        translatedLanguage: .init(identifier: "de")
    ))
    .padding()
}
