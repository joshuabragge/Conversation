import AVFoundation
import Foundation

#if DEBUG
/// DEBUG-only store of recently captured utterances — audio file plus full
/// pipeline diagnostics — backing `CaptureListView`/`CaptureDetailView`.
///
/// Lives entirely behind `#if DEBUG`: this persists raw voice recordings to
/// disk, which nothing in a Release/TestFlight/App Store build should do
/// implicitly. `ConversationLoopController.process` is the only caller,
/// and every call site is itself wrapped in `#if DEBUG` — see its doc
/// comment.
///
/// Stored in `Caches`, not `Application Support` like
/// `ConversationHistoryStore` — unlike real chat history, this is
/// disposable debug data: fine for iOS to purge under storage pressure,
/// and (unlike Application Support) never included in a device/iCloud
/// backup, which matters more here since this is raw voice audio rather
/// than just transcript text.
@MainActor
final class CaptureStore: ObservableObject {
    static let shared = CaptureStore()

    /// Newest first, matching `ConversationHistoryStore.sessions`' convention.
    @Published private(set) var captures: [CaptureRecord] = []

    /// Keeps only the most recent N — old capture audio otherwise costs
    /// real device storage indefinitely for no benefit, since a debugging
    /// session only ever needs to look back a handful of turns.
    private let maxCaptures = 20

    private let directory: URL
    private let metadataURL: URL

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = caches.appendingPathComponent("DebugCaptures", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        metadataURL = directory.appendingPathComponent("captures.json")
        load()
    }

    func audioURL(for capture: CaptureRecord) -> URL {
        directory.appendingPathComponent(capture.audioFilename)
    }

    /// Copies `sourceFileURL` into permanent storage and records
    /// everything the pipeline learned about it. The caller
    /// (`ConversationLoopController.process`) must call this while
    /// `sourceFileURL` — its temp utterance file — is still on disk;
    /// `process`'s `defer` deletes it right after this returns.
    func record(
        sourceFileURL: URL,
        languagePair: LanguagePair,
        manualOverride: Locale.Language?,
        languageID: CaptureLanguageIDInfo?,
        transcriptAttempts: [CaptureTranscriptAttempt],
        outcome: CaptureOutcome
    ) {
        let filename = "\(UUID().uuidString).caf"
        let destination = directory.appendingPathComponent(filename)
        do {
            try FileManager.default.copyItem(at: sourceFileURL, to: destination)
        } catch {
            AppLog.error(.debugCapture, "record: failed to copy audio from \(sourceFileURL.lastPathComponent): \(error.localizedDescription)")
            return
        }

        // Measured off the copied file rather than taken from whatever
        // format the recorder intended — the point is to catch the case
        // where those two disagree. See `CaptureAudioInfo`'s doc comment.
        var audioInfo: CaptureAudioInfo?
        if let file = try? AVAudioFile(forReading: destination) {
            let format = file.fileFormat
            audioInfo = CaptureAudioInfo(
                sampleRate: format.sampleRate, channels: format.channelCount,
                durationSeconds: format.sampleRate > 0 ? Double(file.length) / format.sampleRate : 0
            )
        } else {
            AppLog.error(.debugCapture, "record: couldn't reopen \(filename) to measure it — empty or malformed?")
        }

        let capture = CaptureRecord(
            id: UUID(), recordedAt: Date(), audioFilename: filename,
            languagePairFirst: languagePair.first.minimalIdentifier,
            languagePairSecond: languagePair.second.minimalIdentifier,
            manualOverride: manualOverride?.minimalIdentifier,
            languageID: languageID, transcriptAttempts: transcriptAttempts, outcome: outcome,
            audio: audioInfo
        )
        captures.insert(capture, at: 0)
        AppLog.info(.debugCapture, "record: saved capture \(capture.id) (\(filename))")

        while captures.count > maxCaptures {
            let dropped = captures.removeLast()
            try? FileManager.default.removeItem(at: audioURL(for: dropped))
        }
        persist()
    }

    func delete(_ capture: CaptureRecord) {
        AppLog.info(.debugCapture, "delete: capture \(capture.id)")
        try? FileManager.default.removeItem(at: audioURL(for: capture))
        captures.removeAll { $0.id == capture.id }
        persist()
    }

    func deleteAll() {
        AppLog.info(.debugCapture, "deleteAll: removing \(captures.count) capture(s)")
        for capture in captures {
            try? FileManager.default.removeItem(at: audioURL(for: capture))
        }
        captures.removeAll()
        persist()
    }

    private func load() {
        guard let data = try? Data(contentsOf: metadataURL) else {
            AppLog.debug(.debugCapture, "load: no captures file yet at \(metadataURL.path)")
            return
        }
        do {
            captures = try JSONDecoder().decode([CaptureRecord].self, from: data)
            AppLog.info(.debugCapture, "load: loaded \(captures.count) capture(s)")
        } catch {
            AppLog.error(.debugCapture, "load: failed to decode captures, starting empty: \(error.localizedDescription)")
        }
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(captures)
            try data.write(to: metadataURL, options: .atomic)
        } catch {
            AppLog.error(.debugCapture, "persist: failed to write captures: \(error.localizedDescription)")
        }
    }
}
#endif
