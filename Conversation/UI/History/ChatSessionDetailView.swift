import SwiftUI
import UIKit

/// Full transcript for one saved session, with a "Select" mode for copying
/// just a subset of turns instead of the whole conversation — each turn
/// (heard + translated text together, the same unit `TranscriptBubbleView`
/// already displays) is one selectable block.
struct ChatSessionDetailView: View {
    let session: ChatSession

    @ObservedObject private var store = ConversationHistoryStore.shared
    @State private var isSelecting = false
    @State private var selectedTurnIDs: Set<UUID> = []
    @State private var showCopiedConfirmation = false

    /// Reflects live store state rather than the snapshot this view was
    /// pushed with — the session this view is showing could still be
    /// actively growing (a session mid-walk, viewed from the drawer while
    /// still recording) or have been deleted out from under it elsewhere.
    private var currentSession: ChatSession {
        store.sessions.first(where: { $0.id == session.id }) ?? session
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(currentSession.turns) { turn in
                    turnRow(turn)
                }
            }
            .padding()
        }
        .overlay {
            if currentSession.turns.isEmpty {
                ContentUnavailableView("No Turns", systemImage: "text.bubble", description: Text("This session has no saved exchanges."))
            }
        }
        .navigationTitle(currentSession.startedAt.formatted(date: .abbreviated, time: .shortened))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(isSelecting ? "Done" : "Select") {
                    isSelecting.toggle()
                    if !isSelecting { selectedTurnIDs.removeAll() }
                }
                .disabled(currentSession.turns.isEmpty)
            }
            ToolbarItem(placement: .bottomBar) {
                if isSelecting {
                    Button {
                        copy(text: selectedText)
                    } label: {
                        Label("Copy Selected (\(selectedTurnIDs.count))", systemImage: "doc.on.doc")
                    }
                    .disabled(selectedTurnIDs.isEmpty)
                } else {
                    Button {
                        copy(text: currentSession.formattedText)
                    } label: {
                        Label("Copy All", systemImage: "doc.on.doc")
                    }
                    .disabled(currentSession.turns.isEmpty)
                }
            }
        }
        .overlay(alignment: .top) {
            if showCopiedConfirmation {
                Text("Copied")
                    .font(.footnote.bold())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showCopiedConfirmation)
    }

    private func turnRow(_ turn: ConversationTurn) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if isSelecting {
                Image(systemName: selectedTurnIDs.contains(turn.id) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selectedTurnIDs.contains(turn.id) ? Color.accentColor : Color.secondary)
                    .imageScale(.large)
                    .padding(.top, 10)
            }
            TranscriptBubbleView(turn: turn)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard isSelecting else { return }
            if selectedTurnIDs.contains(turn.id) {
                selectedTurnIDs.remove(turn.id)
            } else {
                selectedTurnIDs.insert(turn.id)
            }
        }
    }

    private var selectedText: String {
        currentSession.turns
            .filter { selectedTurnIDs.contains($0.id) }
            .map(\.formattedText)
            .joined(separator: "\n\n")
    }

    private func copy(text: String) {
        UIPasteboard.general.string = text
        AppLog.debug(.history, "ChatSessionDetailView: copied \(text.count) character(s) to clipboard")
        showCopiedConfirmation = true
        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            showCopiedConfirmation = false
        }
    }
}

#Preview {
    NavigationStack {
        ChatSessionDetailView(session: ChatSession(
            id: UUID(), startedAt: Date(),
            languagePair: LanguagePair(first: .init(identifier: "en"), second: .init(identifier: "de")),
            turns: [
                ConversationTurn(heardText: "Where is the train station?", heardLanguage: .init(identifier: "en"), translatedText: "Wo ist der Bahnhof?", translatedLanguage: .init(identifier: "de")),
                ConversationTurn(heardText: "Es ist gleich um die Ecke.", heardLanguage: .init(identifier: "de"), translatedText: "It's just around the corner.", translatedLanguage: .init(identifier: "en")),
            ]
        ))
    }
}
