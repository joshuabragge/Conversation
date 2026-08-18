import SwiftUI

struct TranscriptBubbleView: View {
    let turn: ConversationTurn
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            bubbleInput(text: turn.heardText, language: turn.heardLanguage, tint: .accentColor)
            if let feedback = turn.feedback {
                feedbackLine(feedback)
            }
            Divider()
            bubbleTranslated(text: turn.translatedText, language: turn.translatedLanguage, tint: .secondary)
        }
    }

    /// The feature-flagged local-LLM coach's note on `heardText`
    /// (`FeedbackConfig.isEnabled`, `Conversation/Feedback/`), populated
    /// asynchronously a moment after the bubble first appears — the first
    /// "arrives later" field on `ConversationTurn`, so it fades in rather
    /// than popping, same idiom `StatusBannerView` uses for its transient
    /// status text.
    private func feedbackLine(_ text: String) -> some View {
        Label(text, systemImage: "sparkles")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .transition(.opacity)
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
