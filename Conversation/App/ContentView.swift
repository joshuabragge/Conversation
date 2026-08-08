import SwiftUI

/// App root — routes between onboarding (first run, or re-entered from
/// Settings to change languages) and the real conversation screen. All
/// the actual milestone test-harness logic from M1–M7 has moved into
/// `ConversationLoopController` and its supporting modules; this view is
/// now just navigation.
struct ContentView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        switch appState.screen {
        case .onboarding:
            OnboardingCoordinatorView()
        case .conversation:
            if let pair = appState.languagePair {
                ConversationView(pair: pair)
            } else {
                // Shouldn't happen (screen only becomes .conversation once
                // a pair is set), but fall back to onboarding rather than
                // showing a broken screen if it ever does.
                OnboardingCoordinatorView()
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState())
        .environmentObject(TranslationService())
}
