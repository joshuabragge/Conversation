import Foundation

#if DEBUG
/// One attempted on-device transcription of a capture's audio, in one
/// locale. A single turn can try up to two locales — the `needsCrossCheck`
/// path tries both candidates up front, and the fast (high-confidence)
/// path added a same-clip retry in the *other* locale if the picked one
/// comes back empty (see `ConversationLoopController.process`) — and this
/// exists specifically to show every attempt, not just whichever text
/// ultimately won, since seeing both side by side is what actually
/// explains a rejection.
struct CaptureTranscriptAttempt: Codable, Equatable {
    let locale: String
    /// `nil` means nothing was transcribed — see `error` and
    /// `finishedNormally` to tell apart *why*, which is the whole reason
    /// this mirrors `TranscriptionResult` instead of just keeping the old
    /// bare `String?`: a real capture showed both candidate locales
    /// coming back empty for clearly audible, correctly-identified
    /// speech, and there was no way to tell whether Apple's STT
    /// genuinely found nothing or just never got the chance to.
    let text: String?
    /// Set only if on-device recognition was unavailable for this locale,
    /// or the recognition task itself errored — `nil` even when `text` is
    /// also nil just means "recognized nothing," not "something broke."
    let error: String?
    /// False if the ~5s fallback timeout elapsed before Apple's `isFinal`
    /// fired, rather than the recognizer finishing on its own — see
    /// `SpeechRecognizerWrapper.TranscriptionResult`'s doc comment.
    let finishedNormally: Bool
    let elapsedSeconds: Double
}

/// WhisperKit's language-ID verdict for a capture — `nil` on the
/// `CaptureRecord` this belongs to if a manual language override skipped
/// identification entirely, or if identification itself never completed
/// (timed out/threw, caught by the outer `catch` in `process`).
struct CaptureLanguageIDInfo: Codable, Equatable {
    let pickedLanguage: String
    let confidence: Double
    let rawLogProb: Double
    let needsCrossCheck: Bool
}

/// How a capture's turn concluded, for the debug page's status badge and
/// detail section. Deliberately doesn't try to represent "TTS also failed
/// afterward" — that's a separate, already-visible-elsewhere concern (the
/// Debug Log); this is scoped to what the LID → transcribe → translate
/// half of the pipeline produced, per the "see what both translations came
/// out as" ask this page exists to answer.
enum CaptureOutcome: Codable, Equatable {
    case accepted(spokenLanguage: String, heardText: String, translatedLanguage: String, translatedText: String)
    case rejected(String)
    case error(String)
}

extension CaptureTranscriptAttempt {
    /// One-line summary for `CaptureListView`'s row — leads with the text
    /// (or its absence), then whichever of `error`/`finishedNormally`
    /// actually explains that absence, so "why is Apple failing" doesn't
    /// require opening the detail view just to see the reason.
    var summary: String {
        var parts = [text?.isEmpty == false ? "\"\(text!)\"" : "(empty)"]
        if !finishedNormally {
            parts.append("timed out after \(String(format: "%.1f", elapsedSeconds))s")
        } else if let error {
            parts.append("error: \(error)")
        }
        return parts.joined(separator: " — ")
    }
}

/// One recorded utterance plus everything the pipeline concluded about
/// it — audio filename (see `CaptureStore.audioURL(for:)`), the
/// language-ID verdict, every locale Apple's STT was actually asked to
/// transcribe it in, and the final outcome.
struct CaptureRecord: Identifiable, Codable, Equatable {
    let id: UUID
    let recordedAt: Date
    let audioFilename: String
    let languagePairFirst: String
    let languagePairSecond: String
    let manualOverride: String?
    let languageID: CaptureLanguageIDInfo?
    let transcriptAttempts: [CaptureTranscriptAttempt]
    let outcome: CaptureOutcome
}
#endif
