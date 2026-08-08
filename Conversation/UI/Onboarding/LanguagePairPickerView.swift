import SwiftUI
import UIKit

struct LanguagePairPickerView: View {
    let onContinue: (LanguagePair) -> Void

    @State private var available: [Locale.Language] = []
    @State private var first: Locale.Language?
    @State private var second: Locale.Language?

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Choose your two languages")
                .font(.title2.bold())
                .padding(.top, 40)

            Text("Only languages with on-device speech recognition on this device are listed.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if available.isEmpty {
                ProgressView("Checking available languages…")
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
            } else if available.count < 2 {
                // Seen in the field with only one language surfacing —
                // rather than show a picker with an empty/broken second
                // dropdown, explain what's actually going on: this reflects
                // which dictation languages are enabled on the device, not
                // an app bug you can fix by retrying.
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

            Spacer()

            Button {
                guard let first, let second else { return }
                onContinue(LanguagePair(first: first, second: second))
            } label: {
                Text("Continue")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(first == nil || second == nil || first == second)
            .padding(.bottom, 40)
        }
        .padding(.horizontal, 32)
        .task {
            available = await SupportedLanguages.availableOnThisDevice()
            first = available.first(where: { $0.minimalIdentifier == "en" }) ?? available.first
            second = available.first(where: { $0 != first })
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

#Preview {
    LanguagePairPickerView(onContinue: { _ in })
}
