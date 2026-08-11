import SwiftUI

#if DEBUG
/// DEBUG-only page listing every recently captured utterance —
/// `CaptureStore`'s whole reason to exist. Lets you play back the exact
/// audio clip alongside everything the pipeline concluded about it: which
/// language WhisperKit picked (and how confidently), what Apple's STT
/// transcribed it as in *every* locale actually tried (not just the
/// winner), and the final outcome. Built specifically because a real
/// device log once showed a correctly-identified language still getting
/// rejected — Apple's STT had come back with an empty transcript for it —
/// and reconstructing that story took reading raw log lines rather than
/// just listening to the clip and seeing both transcription attempts side
/// by side; this page is that shortcut for next time.
struct CaptureListView: View {
    @ObservedObject private var store = CaptureStore.shared
    @State private var confirmDeleteAll = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.captures) { capture in
                    NavigationLink {
                        CaptureDetailView(capture: capture)
                    } label: {
                        CaptureRowView(capture: capture)
                    }
                }
                .onDelete { offsets in
                    for index in offsets { store.delete(store.captures[index]) }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Captures (\(store.captures.count))")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) { confirmDeleteAll = true } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(store.captures.isEmpty)
                }
            }
            .confirmationDialog(
                "Delete all \(store.captures.count) captured clip(s)? This can't be undone.",
                isPresented: $confirmDeleteAll, titleVisibility: .visible
            ) {
                Button("Delete All", role: .destructive) { store.deleteAll() }
                Button("Cancel", role: .cancel) {}
            }
            .overlay {
                if store.captures.isEmpty {
                    ContentUnavailableView(
                        "No captures yet",
                        systemImage: "waveform",
                        description: Text("Every utterance the app hears gets logged here (Debug builds only). Say something to the app, then come back.")
                    )
                }
            }
        }
    }
}

private struct CaptureRowView: View {
    let capture: CaptureRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(capture.recordedAt.formatted(date: .omitted, time: .standard))
                    .font(.subheadline)
                Spacer()
                OutcomeBadge(outcome: capture.outcome)
            }
            if let languageID = capture.languageID {
                Text("LID: \(languageID.pickedLanguage) (\(Int(languageID.confidence * 100))%, logProb=\(String(format: "%.2f", languageID.rawLogProb)))\(languageID.needsCrossCheck ? " · cross-checked" : "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(capture.transcriptAttempts, id: \.locale) { attempt in
                Text("\(attempt.locale): \(attempt.summary)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct OutcomeBadge: View {
    let outcome: CaptureOutcome

    private var text: String {
        switch outcome {
        case .accepted: return "Accepted"
        case .rejected: return "Rejected"
        case .error: return "Error"
        }
    }

    private var color: Color {
        switch outcome {
        case .accepted: return .green
        case .rejected: return .orange
        case .error: return .red
        }
    }

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

#Preview {
    CaptureListView()
}
#endif
