import SwiftUI

/// In-place language pair editor for Settings — no onboarding restart, no
/// re-requesting permissions that are already granted. Replaced the old
/// `LanguagePairEditView`, which just sent you back through the entire
/// onboarding flow (Welcome → Permissions → picker → asset check) for
/// what should be a two-field change.
struct LanguagePairEditorView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var translationService: TranslationService
    @Environment(\.dismiss) private var dismiss

    @State private var available: [Locale.Language] = []
    @State private var isLoading = true
    @State private var first: Locale.Language?
    @State private var second: Locale.Language?
    @State private var isSaving = false
    @State private var saveError: String?

    var body: some View {
        Form {
            Section {
                LanguagePairFieldsView(available: available, isLoading: isLoading, first: $first, second: $second)
            } footer: {
                Text("Only languages with on-device speech recognition on this device are listed.")
            }

            Section {
                Button {
                    Task { await loadAvailableLanguages() }
                } label: {
                    Label("Refresh available languages", systemImage: "arrow.clockwise")
                }
                .disabled(isLoading)
            } footer: {
                Text("If you just enabled a new dictation language or downloaded a voice in system Settings, refresh to pick it up without relaunching.")
            }

            if let saveError {
                Section {
                    Text(saveError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Languages")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if isSaving {
                    ProgressView()
                } else {
                    Button("Save") { Task { await save() } }
                        .disabled(first == nil || second == nil || first == second || isLoading)
                }
            }
        }
        .task {
            first = appState.languagePair?.first
            second = appState.languagePair?.second
            await loadAvailableLanguages()
        }
    }

    private func loadAvailableLanguages() async {
        isLoading = true
        available = await SupportedLanguages.availableOnThisDevice()
        isLoading = false
        // Keep the existing selection if it's still valid; only fall back
        // if it's genuinely no longer available, rather than silently
        // resetting a perfectly good choice every refresh.
        if let first, !available.contains(first) { self.first = available.first }
        if let second, !available.contains(second) { self.second = available.first(where: { $0 != self.first }) }
    }

    private func save() async {
        guard let first, let second else { return }
        let newPair = LanguagePair(first: first, second: second)
        isSaving = true
        saveError = nil
        defer { isSaving = false }

        // The new pair may need its own Translation language pack — prime
        // it the same way onboarding's AssetCheckView does, so switching
        // languages here doesn't surprise you with a download mid-turn later.
        let status = await LanguageAssetChecker.status(from: first, to: second)
        if status == .unsupported {
            saveError = "This language pair isn't supported by on-device Translation."
            return
        }
        if status == .supportedNotInstalled {
            do {
                _ = try await withTimeout(seconds: 60) {
                    try await translationService.translate("hello", from: first, to: second)
                }
            } catch {
                // Non-fatal — same fallback as onboarding: it can still
                // prime during the first real conversation turn instead.
                AppLog.error(.onboarding, "LanguagePairEditorView: pack priming failed: \(error.localizedDescription)")
            }
        }

        appState.updateLanguagePair(newPair)
        dismiss()
    }
}
