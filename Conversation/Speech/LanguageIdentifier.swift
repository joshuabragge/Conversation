import Foundation
import WhisperKit

enum LanguageIdentifierError: Error {
    case noResult
}

struct LanguageIdentificationResult {
    let language: Locale.Language
    /// Renormalized across just the two candidates (not WhisperKit's full
    /// ~100-language distribution) — see `RecognitionConfig.languageIDRejectThreshold`.
    let confidence: Double
    var isConfident: Bool { confidence >= RecognitionConfig.languageIDRejectThreshold }
}

/// Identifies which of two known candidate languages a recorded utterance
/// was spoken in, using WhisperKit's tiny multilingual model for a single
/// cheap language-ID pass — not for transcription (`SpeechRecognizerWrapper`
/// does that, on-device via Apple's own `Speech` framework, once the
/// language is known).
///
/// This is what sidesteps `SFSpeechRecognizer`'s one-live-locale-at-a-time
/// limit (see M4/plan notes): no guessing a locale and retrying the other
/// one on the same buffer, no confidence-blending heuristic against a
/// second live recognizer — one WhisperKit pass gives a definitive answer
/// up front.
@MainActor
final class LanguageIdentifier: ObservableObject {
    @Published private(set) var isLoadingModel = false
    @Published private(set) var errorMessage: String?

    private var whisperKit: WhisperKit?

    /// Loads the tiny model once, lazily, on first use. Downloads from
    /// Hugging Face the first time (needs network, like the Translation
    /// framework's one-time language-pack download) and is cached
    /// on-device after — consistent with the app's "offline after initial
    /// setup" promise.
    private func loadedWhisperKit() async throws -> WhisperKit {
        if let whisperKit { return whisperKit }
        isLoadingModel = true
        defer { isLoadingModel = false }
        let kit = try await WhisperKit(WhisperKitConfig(model: "tiny", verbose: false, logLevel: .none))
        whisperKit = kit
        return kit
    }

    /// Returns which of `candidates` WhisperKit's tiny model thinks was
    /// spoken in the clip at `fileURL`, with a confidence renormalized
    /// across just those two candidates — not WhisperKit's full
    /// ~100-language distribution, since we only ever care about a binary
    /// choice here.
    ///
    /// Uses WhisperKit's top-level `detectLangauge(audioArray:)` (yes, that
    /// misspelling is the real public API name) rather than the
    /// `transcribe(...)` + `detectLanguage: true` shortcut M5 started with:
    /// this one surfaces the actual per-language probability distribution
    /// (`langProbs`), not just the single winning language, which is what
    /// M6's confidence-gated accept/reject scheme needs.
    func identify(fileURL: URL, candidates: [Locale.Language]) async throws -> LanguageIdentificationResult {
        let kit = try await loadedWhisperKit()
        let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: fileURL.path, channelMode: .sumChannels(nil))
        let (_, langProbs) = try await kit.detectLangauge(audioArray: samples)

        let rawProbs = candidates.map { Double(langProbs[$0.languageCode?.identifier ?? ""] ?? 0) }
        return try Self.pickWinner(candidates: candidates, rawProbs: rawProbs)
    }

    /// Pure and independently unit-testable: renormalizes `rawProbs`
    /// (WhisperKit's raw per-candidate probabilities, which sum to well
    /// under 1 since they're a slice of its full ~100-language
    /// distribution) across just the candidates the user actually chose,
    /// and picks the winner. Split out from `identify` so the confidence
    /// math can be verified against fixtures without a device or a loaded
    /// model.
    nonisolated static func pickWinner(candidates: [Locale.Language], rawProbs: [Double]) throws -> LanguageIdentificationResult {
        precondition(candidates.count == rawProbs.count)
        let total = rawProbs.reduce(0, +)
        let renormalized = total > 0 ? rawProbs.map { $0 / total } : candidates.map { _ in 1.0 / Double(candidates.count) }

        guard let bestIndex = renormalized.indices.max(by: { renormalized[$0] < renormalized[$1] }) else {
            throw LanguageIdentifierError.noResult
        }
        return LanguageIdentificationResult(language: candidates[bestIndex], confidence: renormalized[bestIndex])
    }
}
