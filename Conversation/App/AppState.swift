import Foundation

/// Top-level navigation: onboarding (first run, or re-entered from
/// Settings to change languages) vs. the main conversation screen.
/// Persists only the chosen language pair — no history/vocab data, per v1
/// scope.
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
        languagePair = pair
        if let data = try? JSONEncoder().encode(pair) {
            UserDefaults.standard.set(data, forKey: Self.languagePairKey)
        }
        screen = .conversation
    }

    /// Re-enters onboarding's language step (from Settings) without
    /// forgetting the previous pair unless the user actually finishes
    /// picking a new one.
    func changeLanguagePair() {
        AppLog.info(.onboarding, "changeLanguagePair: returning to onboarding")
        screen = .onboarding
    }
}
