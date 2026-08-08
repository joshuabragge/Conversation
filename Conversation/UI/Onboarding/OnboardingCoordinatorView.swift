import SwiftUI

struct OnboardingCoordinatorView: View {
    @EnvironmentObject private var appState: AppState

    private enum Step {
        case welcome
        case permissions
        case languagePair
        case assetCheck(LanguagePair)
    }

    @State private var step: Step = .welcome

    var body: some View {
        Group {
            switch step {
            case .welcome:
                WelcomeView(onContinue: { step = .permissions })
            case .permissions:
                // Permissions before the language picker, not after: the
                // picker's `SupportedLanguages.availableOnThisDevice()`
                // call depends on `SFSpeechRecognizer.supportsOnDeviceRecognition`,
                // which is unreliable before speech-recognition
                // authorization has ever been granted — observed producing
                // a short/inconsistent language list when queried too early.
                PermissionsRequestView(onContinue: { step = .languagePair })
            case .languagePair:
                LanguagePairPickerView(onContinue: { pair in
                    step = .assetCheck(pair)
                })
            case .assetCheck(let pair):
                AssetCheckView(pair: pair, onContinue: {
                    appState.completeOnboarding(with: pair)
                })
            }
        }
        .animation(.default, value: isWelcomeStep)
    }

    private var isWelcomeStep: Bool {
        if case .welcome = step { return true }
        return false
    }
}

#Preview {
    OnboardingCoordinatorView()
        .environmentObject(AppState())
        .environmentObject(TranslationService())
}
