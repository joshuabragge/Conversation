import Foundation

/// Top-level navigation: onboarding (first run only) vs. the main
/// conversation screen. Persists only the chosen language pair — no
/// history/vocab data, per v1 scope.
@MainActor
final class AppState: ObservableObject {
    enum Screen {
        case onboarding
        case conversation
    }

    @Published var screen: Screen
    @Published var languagePair: LanguagePair?

    private static let languagePairKey = "com.joshuabragge.Conversation.languagePair"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.languagePairKey),
           let pair = try? JSONDecoder().decode(LanguagePair.self, from: data) {
            languagePair = pair
            screen = .conversation
            AppLog.info(.onboarding, "AppState.init: found persisted pair \(pair.first.minimalIdentifier)/\(pair.second.minimalIdentifier), skipping onboarding")
        } else {
            screen = .onboarding
            AppLog.info(.onboarding, "AppState.init: no persisted pair, starting onboarding")
        }
    }

    func completeOnboarding(with pair: LanguagePair) {
        AppLog.info(.onboarding, "completeOnboarding: \(pair.first.minimalIdentifier)/\(pair.second.minimalIdentifier)")
        persist(pair)
        screen = .conversation
    }

    /// Changes the active pair in place from Settings — no onboarding
    /// restart, no re-requesting permissions that are already granted.
    /// `ConversationView` observes `languagePair` and pushes the change
    /// into the live `ConversationLoopController` itself.
    func updateLanguagePair(_ pair: LanguagePair) {
        AppLog.info(.onboarding, "updateLanguagePair: \(pair.first.minimalIdentifier)/\(pair.second.minimalIdentifier)")
        persist(pair)
    }

    private func persist(_ pair: LanguagePair) {
        languagePair = pair
        if let data = try? JSONEncoder().encode(pair) {
            UserDefaults.standard.set(data, forKey: Self.languagePairKey)
        }
    }
}
