import SwiftUI

@main
struct ConversationApp: App {
    // Owned at the app root so the hidden TranslationSessionHost (and thus
    // the underlying TranslationSession) survives for the whole app
    // lifetime rather than being recreated per screen.
    @StateObject private var translationService = TranslationService()
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(translationService)
                .environmentObject(appState)
                .background {
                    TranslationSessionHost(service: translationService)
                }
        }
    }
}
