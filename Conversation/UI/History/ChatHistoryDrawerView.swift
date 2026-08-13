import SwiftUI
import UIKit

/// The sliding history drawer opened from `ConversationView`'s hamburger
/// button. Owns its own `NavigationStack` so tapping into a session's full
/// transcript pushes within the drawer itself, independent of the main
/// screen's navigation underneath it.
struct ChatHistoryDrawerView: View {
    @Binding var isPresented: Bool
    @ObservedObject private var store = ConversationHistoryStore.shared
    @State private var confirmDeleteAll = false
    
    var body: some View {
        
        NavigationStack {
            VStack(spacing: 0) {
                // Manual header — lives inside the 300pt frame, unlike toolbar items
                HStack {
                    Button {
                        isPresented = false
                    } label: {
                        Image(systemName: "line.3.horizontal")
                    }

                    Spacer()

                    Text("History")
                        .font(.headline)

                    Spacer()
                    if !store.sessions.isEmpty {
                        Button(role: .destructive) {
                            confirmDeleteAll = true
                        } label: {
                            Image(systemName: "trash")
                        }
                    }
                }
                .padding()
                .background(.background)
                
                Divider()
                
                Group {
                    if store.sessions.isEmpty {
                        ContentUnavailableView(
                            "No Conversations Yet", systemImage: "clock.arrow.circlepath",
                            description: Text("Sessions are saved automatically once they have at least one translated exchange.")
                        )
                    } else {
                        List {
                            ForEach(store.sessions) { session in
                                NavigationLink {
                                    ChatSessionDetailView(session: session)
                                } label: {
                                    ChatHistoryRowView(session: session)
                                }
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        store.delete(session)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                    Button {
                                        UIPasteboard.general.string = session.formattedText
                                    } label: {
                                        Label("Copy", systemImage: "doc.on.doc")
                                    }
                                    .tint(.accentColor)
                                }
                            }
                        }
                        .listStyle(.plain)
                    }
                }
            }
            .navigationBarHidden(true)
            .confirmationDialog(
                "Delete all saved conversations? This can't be undone.",
                isPresented: $confirmDeleteAll, titleVisibility: .visible
            ) {
                Button("Delete All", role: .destructive) { store.deleteAll() }
                Button("Cancel", role: .cancel) {}
            }
        }
    }
}

#Preview {
    ChatHistoryDrawerView(isPresented: .constant(true))
}
