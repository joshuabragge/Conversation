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
                        TranscriptAttemptRow(attempt: attempt)
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

/// One `CaptureTranscriptAttempt`'s row — split out from `CaptureDetailView`
/// because inlining this much conditional text/color logic directly in a
/// `List` body blew past the type-checker's time budget ("unable to
/// type-check this expression in reasonable time").
private struct TranscriptAttemptRow: View {
    let attempt: CaptureTranscriptAttempt

    private var transcriptText: String {
        attempt.text?.isEmpty == false ? attempt.text! : "(empty transcript)"
    }

    // Distinguishes "the recognizer genuinely found nothing" from "it
    // never got the chance to" — an empty transcript alone can't tell
    // those apart, which is exactly what made a real device capture
    // ambiguous (see CLAUDE.md).
    private var timingText: String {
        attempt.finishedNormally
            ? "completed normally in \(String(format: "%.2f", attempt.elapsedSeconds))s"
            : "⚠️ timed out after \(String(format: "%.2f", attempt.elapsedSeconds))s waiting for isFinal"
    }

    private var timingColor: Color {
        attempt.finishedNormally ? .secondary : .orange
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(attempt.locale.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(transcriptText)
                .italic(attempt.text?.isEmpty != false)
            Text(timingText)
                .font(.caption2)
                .foregroundStyle(timingColor)
            if let error = attempt.error {
                Text("Error: \(error)")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 2)
    }
}
#endif
