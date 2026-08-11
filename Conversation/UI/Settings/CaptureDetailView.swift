import SwiftUI

#if DEBUG
/// Playback + full diagnostics for one `CaptureRecord` — see
/// `CaptureListView`'s doc comment for why this page exists.
struct CaptureDetailView: View {
    let capture: CaptureRecord
    @StateObject private var player = CaptureAudioPlayer()

    var body: some View {
        List {
            Section {
                Button {
                    if player.isPlaying {
                        player.stop()
                    } else {
                        player.play(url: CaptureStore.shared.audioURL(for: capture))
                    }
                } label: {
                    Label(player.isPlaying ? "Stop" : "Play", systemImage: player.isPlaying ? "stop.fill" : "play.fill")
                }
                LabeledContent("Recorded", value: capture.recordedAt.formatted(date: .abbreviated, time: .standard))
                LabeledContent("Language pair", value: "\(capture.languagePairFirst) \u{21C4} \(capture.languagePairSecond)")
                if let manualOverride = capture.manualOverride {
                    LabeledContent("Manual override", value: manualOverride)
                }
            }

            if let languageID = capture.languageID {
                Section("Language ID (WhisperKit)") {
                    LabeledContent("Picked", value: languageID.pickedLanguage)
                    LabeledContent("Confidence", value: "\(Int(languageID.confidence * 100))%")
                    LabeledContent("Raw log-prob", value: String(format: "%.3f", languageID.rawLogProb))
                    LabeledContent("Needed cross-check", value: languageID.needsCrossCheck ? "Yes" : "No")
                }
            }

            if !capture.transcriptAttempts.isEmpty {
                Section("Transcription attempts (Apple STT)") {
                    ForEach(capture.transcriptAttempts, id: \.locale) { attempt in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(attempt.locale.uppercased())
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(attempt.text?.isEmpty == false ? attempt.text! : "(empty transcript)")
                                .italic(attempt.text?.isEmpty != false)
                        }
                    }
                }
            }

            Section("Outcome") {
                switch capture.outcome {
                case .accepted(let spokenLanguage, let heardText, let translatedLanguage, let translatedText):
                    LabeledContent("Spoken (\(spokenLanguage))", value: heardText)
                    LabeledContent("Translated (\(translatedLanguage))", value: translatedText)
                case .rejected(let reason):
                    Label(reason, systemImage: "xmark.circle")
                        .foregroundStyle(.orange)
                case .error(let message):
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Capture")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { player.stop() }
    }
}
#endif
