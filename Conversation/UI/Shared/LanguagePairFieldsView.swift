import SwiftUI
import UIKit

/// Shared language-pair selection UI, used by onboarding's
/// `LanguagePairPickerView` (first run) and Settings'
/// `LanguagePairEditorView` (changing languages later) so both stay
/// consistent without duplicating the "too few languages" messaging.
struct LanguagePairFieldsView: View {
    let available: [Locale.Language]
    let isLoading: Bool
    @Binding var first: Locale.Language?
    @Binding var second: Locale.Language?

    var body: some View {
        if isLoading {
            ProgressView("Checking available languages…")
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
        } else if available.count < 2 {
            // Seen in the field with only one language surfacing — rather
            // than show a picker with an empty/broken second dropdown,
            // explain what's actually going on: this reflects which
            // dictation languages are enabled on the device, not an app
            // bug you can fix by retrying.
            VStack(alignment: .leading, spacing: 12) {
                Label("Only \(available.first?.displayName ?? "one language") is available on this device.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text("Conversation needs two languages with on-device dictation enabled. Add another language in Settings > General > Keyboard > Dictation Languages, then come back.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Link("Open Settings", destination: URL(string: UIApplication.openSettingsURLString)!)
            }
            .padding(.top, 20)
        } else {
            picker(title: "First language", selection: $first, excluding: second)
            picker(title: "Second language", selection: $second, excluding: first)
        }
    }

    private func picker(title: String, selection: Binding<Locale.Language?>, excluding: Locale.Language?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Picker(title, selection: selection) {
                ForEach(available.filter { $0 != excluding }, id: \.minimalIdentifier) { language in
                    Text(language.displayName).tag(Optional(language))
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
