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

    /// Loads the tiny model once. Downloads from Hugging Face the first
    /// time (needs network, like the Translation framework's one-time
    /// language-pack download) and is cached on-device after — consistent
    /// with the app's "offline after initial setup" promise.
    ///
    /// Called eagerly during onboarding's asset-check step (`prewarm()`)
    /// rather than left purely lazy: leaving it to the first real
    /// conversation turn meant a slow/stuck first-time download showed up
    /// as "Identifying language…" hanging mid-conversation with no
    /// progress indicator, instead of a clearly-labeled one-time setup
    /// step. `identify(fileURL:candidates:)` still calls this too, as a
    /// fallback for whenever onboarding's prewarm didn't happen or didn't
    /// finish (e.g. the user backgrounded the app during it).
    private func loadedWhisperKit() async throws -> WhisperKit {
        if let whisperKit {
            AppLog.debug(.languageID, "loadedWhisperKit: already loaded, reusing")
            return whisperKit
        }
        isLoadingModel = true
        defer { isLoadingModel = false }
        AppLog.info(.languageID, "loadedWhisperKit: loading tiny model (downloads on first run)")
        let start = Date()
        do {
            let kit = try await WhisperKit(WhisperKitConfig(model: "tiny", verbose: false, logLevel: .none))
            whisperKit = kit
            AppLog.info(.languageID, "loadedWhisperKit: ready in \(Date().timeIntervalSince(start))s")
            return kit
        } catch {
            AppLog.error(.languageID, "loadedWhisperKit: failed after \(Date().timeIntervalSince(start))s: \(error.localizedDescription)")
            throw error
        }
    }

    /// Triggers the model download/load ahead of time, so onboarding can
    /// show a real "downloading" state instead of the first conversation
    /// turn silently stalling on it.
    func prewarm() async throws {
        _ = try await loadedWhisperKit()
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
        AppLog.info(.languageID, "identify: starting for \(fileURL.lastPathComponent), candidates=\(candidates.map(\.minimalIdentifier))")
        let start = Date()
        let kit = try await loadedWhisperKit()
        let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: fileURL.path, channelMode: .sumChannels(nil))
        AppLog.debug(.languageID, "identify: loaded \(samples.count) samples from file")
        let (topLanguage, langProbs) = try await kit.detectLangauge(audioArray: samples)
        AppLog.info(.languageID, "identify: WhisperKit's top guess=\(topLanguage), full probs (candidates only)=\(candidates.map { "\($0.minimalIdentifier)=\(langProbs[$0.minimalIdentifier] ?? 0)" })")

        let rawProbs = candidates.map { Double(langProbs[$0.languageCode?.identifier ?? ""] ?? 0) }
        let result = try Self.pickWinner(candidates: candidates, rawProbs: rawProbs)
        AppLog.info(.languageID, "identify: picked \(result.language.minimalIdentifier) confidence=\(result.confidence) (took \(Date().timeIntervalSince(start))s)")
        return result
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
