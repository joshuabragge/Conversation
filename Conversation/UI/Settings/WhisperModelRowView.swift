import SwiftUI

/// One row per WhisperKit model option in Settings: shows whether it's
/// downloaded, a real progress bar while downloading (not just a
/// spinner — `WhisperModelManager` exposes actual fractional progress
/// from WhisperKit's lower-level download API), and a button to fetch it
/// ahead of time rather than waiting for it to be needed mid-conversation.
struct WhisperModelRowView: View {
    let model: WhisperModelOption
    @ObservedObject var manager: WhisperModelManager

    @State private var isDownloaded = false
    @State private var errorMessage: String?

    private var isDownloading: Bool { manager.isDownloading[model] ?? false }
    private var progress: Double { manager.downloadProgress[model] ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(model.displayName)
                Spacer()
                statusView
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .task(id: isDownloading) {
            // Re-checks disk state whenever a download starts/finishes —
            // covers both this row triggering it and another one (e.g. a
            // background prewarm) finishing concurrently.
            isDownloaded = manager.isDownloaded(model)
        }
        .swipeActions(edge: .trailing) {
            // Only offered for a model that's both downloaded and not the
            // bundled tiny one — `manager.delete(_:)` already guards this,
            // but hiding the action entirely reads better than showing a
            // swipe action that would just throw.
            if isDownloaded && !manager.isBundled(model) {
                Button(role: .destructive) {
                    do {
                        try manager.delete(model)
                        isDownloaded = manager.isDownloaded(model)
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    @ViewBuilder
    private var statusView: some View {
        if manager.isBundled(model) {
            // Ships inside the app itself — there's nothing to download or
            // show progress for, so this short-circuits before the
            // isDownloading/isDownloaded checks below.
            Label("Included", systemImage: "shippingbox.fill")
                .labelStyle(.iconOnly)
                .foregroundStyle(.green)
        } else if isDownloading {
            ProgressView(value: progress)
                .frame(width: 90)
        } else if isDownloaded {
            Label("Downloaded", systemImage: "checkmark.circle.fill")
                .labelStyle(.iconOnly)
                .foregroundStyle(.green)
        } else {
            Button("Download") {
                errorMessage = nil
                Task {
                    do {
                        try await manager.download(model)
                        isDownloaded = manager.isDownloaded(model)
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }
}
