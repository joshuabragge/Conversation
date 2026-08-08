import SwiftUI
import Translation

struct AssetCheckView: View {
    let pair: LanguagePair
    let onContinue: () -> Void

    @EnvironmentObject private var translationService: TranslationService
    @StateObject private var speechOutput = SpeechOutputService()
    @StateObject private var languageIdentifier = LanguageIdentifier()

    @State private var packStatus: LanguagePackStatus?
    @State private var packError: String?
    @State private var missingVoices: [Locale.Language] = []
    @State private var isPreparingPack = false
    @State private var modelReady = false
    @State private var modelError: String?

    private var isPreparing: Bool { isPreparingPack || languageIdentifier.isLoadingModel }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Getting ready")
                .font(.title2.bold())
                .padding(.top, 40)

            checkRow(
                title: "\(pair.first.displayName) ⇄ \(pair.second.displayName) translation",
                status: packStatus
            )
            if let packError {
                Text(packError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Language-detection model")
                    Spacer()
                    if modelReady {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    } else if modelError != nil {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                    } else {
                        ProgressView()
                    }
                }
                if languageIdentifier.isLoadingModel {
                    Text("Downloading — one-time, needs network, then works offline.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let modelError {
                    Text(modelError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            if !missingVoices.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("No installed voice for: \(missingVoices.map(\.displayName).joined(separator: ", "))")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                    Text("You can still use Conversation, but won't hear that language spoken aloud until you add a voice in Settings > Accessibility > Spoken Content > Voices.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button {
                onContinue()
            } label: {
                Text(packStatus == .installed && modelReady ? "Continue" : "Continue Anyway")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isPreparing)
            .padding(.bottom, 40)
        }
        .padding(.horizontal, 32)
        .task {
            missingVoices = pair.languages.filter { !speechOutput.hasVoice(for: $0) }
            // Run both prep steps concurrently — independent systems
            // (Translation vs. WhisperKit), no reason to serialize them.
            async let translationPrep: Void = prepareTranslationPack()
            async let modelPrep: Void = prepareLanguageModel()
            _ = await (translationPrep, modelPrep)
        }
    }

    @ViewBuilder
    private func checkRow(title: String, status: LanguagePackStatus?) -> some View {
        HStack {
            Text(title)
            Spacer()
            switch status {
            case nil:
                ProgressView()
            case .installed:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .supportedNotInstalled:
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(.blue)
            case .unsupported:
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            }
        }
    }

    private func prepareTranslationPack() async {
        let status = await LanguageAssetChecker.status(from: pair.first, to: pair.second)
        packStatus = status
        guard status != .unsupported else {
            packError = "This language pair isn't supported by on-device Translation."
            return
        }
        guard status == .supportedNotInstalled else { return }

        // Triggers Translation's system download-consent flow, if needed,
        // by actually performing a real (trivial) translation — the
        // TranslationSessionHost mounted at the app root needs real screen
        // geometry for that system sheet to present (see the M2 finding).
        isPreparingPack = true
        defer { isPreparingPack = false }
        do {
            _ = try await withTimeout(seconds: 60) {
                try await translationService.translate("hello", from: pair.first, to: pair.second)
            }
            packStatus = .installed
        } catch {
            packError = "Couldn't prepare the language pack yet: \(error.localizedDescription). You can continue and it'll retry during your first conversation."
        }
    }

    private func prepareLanguageModel() async {
        do {
            try await withTimeout(seconds: 90) {
                try await languageIdentifier.prewarm()
            }
            modelReady = true
        } catch is TimeoutError {
            modelError = "Taking a while — check your network connection. You can continue; it'll keep trying during your first conversation."
        } catch {
            modelError = "Couldn't download yet: \(error.localizedDescription). You can continue; it'll retry during your first conversation."
        }
    }
}

#Preview {
    AssetCheckView(pair: LanguagePair(first: .init(identifier: "en"), second: .init(identifier: "de")), onContinue: {})
        .environmentObject(TranslationService())
}
