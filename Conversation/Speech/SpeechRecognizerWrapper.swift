import Speech

/// One-shot on-device transcription of an already-recorded utterance file,
/// in whichever locale `LanguageIdentifier` determined.
///
/// Replaces the M1–M4 live-streaming design: `SFSpeechRecognizer` only
/// supports one live locale at a time, so as of M5 the locale is always
/// known *before* transcription starts, and this transcribes a fixed file
/// (`MicrophoneInputManager`'s recorded utterance file) rather than owning
/// a live mic tap itself.
@MainActor
final class SpeechRecognizerWrapper: ObservableObject {
    @Published private(set) var isTranscribing = false
    @Published private(set) var errorMessage: String?

    private var recognitionTask: SFSpeechRecognitionTask?

    /// Transcribes `fileURL` in `locale`. Polls for up to ~5s rather than
    /// depending solely on the recognizer's own `isFinal` callback — M4
    /// found that some input routes (AirPods HFP) don't reliably call it
    /// back at all even for a fixed, complete file. Caps the wait either
    /// way and falls back to whatever's been transcribed so far.
    func transcribe(fileURL: URL, locale: Locale) async -> String? {
        AppLog.info(.transcription, "transcribe: starting for \(fileURL.lastPathComponent) in \(locale.identifier)")
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.supportsOnDeviceRecognition else {
            let message = "On-device recognition isn't available for \(locale.identifier)."
            AppLog.error(.transcription, "transcribe: \(message)")
            errorMessage = message
            return nil
        }

        isTranscribing = true
        errorMessage = nil
        defer { isTranscribing = false }

        let request = SFSpeechURLRecognitionRequest(url: fileURL)
        request.requiresOnDeviceRecognition = true

        var latestText = ""
        var didFinish = false
        var finishedViaFallback = true

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                if let result {
                    latestText = result.bestTranscription.formattedString
                }
                if let error {
                    AppLog.error(.transcription, "transcribe: recognitionTask error: \(error.localizedDescription)")
                    self?.errorMessage = error.localizedDescription
                    didFinish = true
                    finishedViaFallback = false
                } else if result?.isFinal == true {
                    AppLog.debug(.transcription, "transcribe: isFinal callback fired normally")
                    didFinish = true
                    finishedViaFallback = false
                }
            }
        }

        let pollInterval: TimeInterval = 0.1
        let maxPolls = Int(RecognitionConfig.transcriptionFallbackTimeout / pollInterval)
        for _ in 0..<maxPolls {
            if didFinish { break }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }

        if finishedViaFallback {
            AppLog.error(.transcription, "transcribe: timed out waiting for isFinal (M4 AirPods-style stall) — using whatever was transcribed so far: \"\(latestText)\"")
        }

        recognitionTask?.cancel()
        recognitionTask = nil
        AppLog.info(.transcription, "transcribe: result=\"\(latestText)\"")
        return latestText.isEmpty ? nil : latestText
    }
}
