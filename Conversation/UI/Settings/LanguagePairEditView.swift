import SwiftUI

/// Entry point from Settings to change languages — actually re-runs
/// onboarding's language picker + asset check, since changing languages
/// needs the same "is this pair actually ready on this device" checks a
/// first-time setup does.
struct LanguagePairEditView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Button(role: .none) {
            // Dismiss the Settings sheet first — switching `appState.screen`
            // while it's still presented would leave it stacked on top of
            // a view that's about to be torn down.
            dismiss()
            appState.changeLanguagePair()
        } label: {
            Text("Change languages…")
        }
    }
}
