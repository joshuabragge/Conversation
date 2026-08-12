import Speech

/// One attempt at transcribing a clip in one locale — more than just the
/// text, so callers (and `ConversationLoopController`'s DEBUG capture
/// diagnostics) can tell apart *why* `text` came back nil: a genuinely
/// empty result, a real recognizer error, or the ~5s fallback timeout
/// (`RecognitionConfig.transcriptionFallbackTimeout`) elapsing before
/// `isFinal` ever fired. Those point at very different next steps, and
/// collapsing them all to a bare `nil` (the old return type) made that
/// undiagnosable after the fact — a real device capture showed both
/// candidate locales coming back with an empty transcript for clearly
/// audible, correctly-identified speech, with no way to tell from the
/// result alone whether Apple's STT genuinely found nothing or just
/// never got the chance to.
struct TranscriptionResult: Equatable {
    /// nil when nothing was transcribed, for any reason — see `error` and
    /// `finishedNormally` to tell those reasons apart.
    let text: String?
    /// Set only if `SFSpeechRecognizer(locale:)` was unavailable for this
    /// locale, or the recognition task's completion handler delivered a
    /// real `Error`. `nil` even when `text` is also nil just means
    /// "recognized nothing," not "something broke."
    let error: String?
    /// False if the ~5s fallback timeout elapsed before `isFinal` fired,
    /// rather than the recognizer finishing (successfully or with an
    /// error) on its own — confirmed on real AirPods/HFP routes, where
    /// `isFinal` sometimes never fires at all, even for a complete fixed
    /// file. `text` in that case is whatever was transcribed before the
    /// timeout, not necessarily empty.
    let finishedNormally: Bool
    let elapsed: TimeInterval
    /// Whether this ran with `requiresOnDeviceRecognition` — always true
    /// in a Release build; false only when the DEBUG-only
    /// `RecognitionConfig.allowServerBasedRecognition` diagnostic is on.
    let onDevice: Bool
}

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
    func transcribe(fileURL: URL, locale: Locale) async -> TranscriptionResult {
        let start = Date()
        // DEBUG-only diagnostic escape hatch — see
        // `RecognitionConfig.allowServerBasedRecognition`. Always false in
        // a Release build, where this compiles down to the original
        // on-device-only behaviour.
        #if DEBUG
        let requiresOnDevice = !RecognitionConfig.allowServerBasedRecognition
        #else
        let requiresOnDevice = true
        #endif
        AppLog.info(.transcription, "transcribe: starting for \(fileURL.lastPathComponent) in \(locale.identifier) (requiresOnDevice=\(requiresOnDevice))")

        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            let message = "No speech recognizer for \(locale.identifier)."
            AppLog.error(.transcription, "transcribe: \(message)")
            errorMessage = message
            return TranscriptionResult(text: nil, error: message, finishedNormally: false, elapsed: Date().timeIntervalSince(start), onDevice: requiresOnDevice)
        }
        // Only a hard requirement when actually demanding on-device work:
        // this guard used to run unconditionally, which would have made
        // the server-based diagnostic above untestable on exactly the
        // locales worth testing it on (one whose offline asset is
        // missing is precisely the case that reports `false` here).
        guard recognizer.supportsOnDeviceRecognition || !requiresOnDevice else {
            let message = "On-device recognition isn't available for \(locale.identifier)."
            AppLog.error(.transcription, "transcribe: \(message)")
            errorMessage = message
            return TranscriptionResult(text: nil, error: message, finishedNormally: false, elapsed: Date().timeIntervalSince(start), onDevice: requiresOnDevice)
        }

        isTranscribing = true
        errorMessage = nil
        defer { isTranscribing = false }

        let request = SFSpeechURLRecognitionRequest(url: fileURL)
        request.requiresOnDeviceRecognition = requiresOnDevice

        var latestText = ""
        var taskError: String?
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
                    taskError = error.localizedDescription
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
        let elapsed = Date().timeIntervalSince(start)
        AppLog.info(.transcription, "transcribe: result=\"\(latestText)\" finishedNormally=\(!finishedViaFallback) elapsed=\(elapsed)s")
        return TranscriptionResult(
            text: latestText.isEmpty ? nil : latestText, error: taskError,
            finishedNormally: !finishedViaFallback, elapsed: elapsed, onDevice: requiresOnDevice
        )
    }
}
