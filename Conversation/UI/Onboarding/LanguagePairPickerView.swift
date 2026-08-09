import SwiftUI

struct LanguagePairPickerView: View {
    let onContinue: (LanguagePair) -> Void

    @State private var available: [Locale.Language] = []
    @State private var isLoading = true
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

            LanguagePairFieldsView(available: available, isLoading: isLoading, first: $first, second: $second)

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
            isLoading = false
            first = available.first(where: { $0.minimalIdentifier == "en" }) ?? available.first
            second = available.first(where: { $0 != first })
        }
    }
}

#Preview {
    LanguagePairPickerView(onContinue: { _ in })
}
