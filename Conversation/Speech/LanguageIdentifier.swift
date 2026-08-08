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
    /// WhisperKit's own **absolute** log-probability for the winning
    /// candidate (≤ 0; 0 means certainty) — unlike `confidence`, this
    /// isn't relative to the other candidate, so it can catch cases where
    /// `confidence` reads as high only because the other candidate never
    /// appeared in WhisperKit's output at all. See `needsCrossCheck`.
    let rawLogProb: Double
    var isConfident: Bool { confidence >= RecognitionConfig.languageIDRejectThreshold }
    /// True when the model's own absolute confidence in its top pick is
    /// mediocre even though `confidence` (relative to the other candidate)
    /// might read as high — the caller should treat this pick as a
    /// starting guess to verify, not a settled answer. See
    /// `RecognitionConfig.languageIDHighConfidenceLogProb`'s doc comment
    /// for the real device example that motivated this.
    var needsCrossCheck: Bool { rawLogProb < RecognitionConfig.languageIDHighConfidenceLogProb }
}

/// Identifies which of two known candidate languages a recorded utterance
/// was spoken in, using WhisperKit's multilingual model for a single cheap
/// language-ID pass — not for transcription (`SpeechRecognizerWrapper`
/// does that, on-device via Apple's own `Speech` framework, once the
/// language is known).
///
/// This is what sidesteps `SFSpeechRecognizer`'s one-live-locale-at-a-time
/// limit (see M4/plan notes): no guessing a locale and retrying the other
/// one on the same buffer, no confidence-blending heuristic against a
/// second live recognizer — one WhisperKit pass gives a definitive answer
/// up front. That answer isn't always right, though — see
/// `LanguageIdentificationResult.needsCrossCheck` and
/// `ConversationLoopController.crossCheckLanguage` for how a weak one gets
/// double-checked against Apple's own STT instead of trusted blindly.
@MainActor
final class LanguageIdentifier: ObservableObject {
    @Published private(set) var isLoadingModel = false
    @Published private(set) var errorMessage: String?

    private var whisperKit: WhisperKit?
    /// Which model `whisperKit` was actually loaded with — if
    /// `RecognitionConfig.whisperModel` changes after that, the change
    /// won't take effect until a fresh `LanguageIdentifier` loads (see
    /// `RecognitionConfig.whisperModel`'s doc comment).
    private var loadedModelName: String?

    private static func cachedModelFolderKey(for modelName: String) -> String {
        "com.joshuabragge.Conversation.whisperModelFolder.\(modelName)"
    }

    /// Loads the configured model once. Downloads from Hugging Face the
    /// first time (needs network, like the Translation framework's
    /// one-time language-pack download) and is cached on-device after —
    /// consistent with the app's "offline after initial setup" promise.
    ///
    /// **This didn't actually hold before**: read into WhisperKit's own
    /// source and found that its default resolution path (used whenever
    /// `modelFolder` isn't explicitly supplied, which is what this method
    /// used to do every time) unconditionally calls the Hugging Face Hub
    /// API to list filenames *before* ever touching a local cache — on
    /// every single app launch, not just the first. That's a real,
    /// confirmed bug behind "worked online, broke offline on relaunch,
    /// even for the model that was already working": the model files
    /// were genuinely cached, but the network call to look them up
    /// wasn't skippable without explicitly pointing at that cache.
    ///
    /// Fix: after a successful load, the resolved `WhisperKit.modelFolder`
    /// is saved (per model name, since tiny/base cache to different
    /// folders). Next time, if that folder still exists on disk, it's
    /// passed back in as `modelFolder`, which makes WhisperKit skip
    /// `download()` (and its network call) entirely. Falls back to the
    /// normal network-resolving path if the cached folder is missing or
    /// fails to load (stale/corrupt), so a bad cache entry can't
    /// permanently break loading once network is available again.
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
        let modelName = RecognitionConfig.whisperModel.modelName
        if let whisperKit, loadedModelName == modelName {
            AppLog.debug(.languageID, "loadedWhisperKit: already loaded (\(modelName)), reusing")
            return whisperKit
        }
        isLoadingModel = true
        defer { isLoadingModel = false }

        let cacheKey = Self.cachedModelFolderKey(for: modelName)
        let cachedPath = UserDefaults.standard.string(forKey: cacheKey)
        let cachedFolderExists = cachedPath.map { FileManager.default.fileExists(atPath: $0) } ?? false
        AppLog.info(.languageID, "loadedWhisperKit: loading '\(modelName)' (cached local folder \(cachedFolderExists ? "found: \(cachedPath!)" : "not found — will need network"))")

        let start = Date()
        do {
            let kit = try await WhisperKit(WhisperKitConfig(
                model: modelName,
                modelFolder: cachedFolderExists ? cachedPath : nil,
                verbose: false, logLevel: .none
            ))
            cacheModelFolder(from: kit, key: cacheKey)
            whisperKit = kit
            loadedModelName = modelName
            AppLog.info(.languageID, "loadedWhisperKit: ready in \(Date().timeIntervalSince(start))s (usedCachedFolder=\(cachedFolderExists))")
            return kit
        } catch {
            guard cachedFolderExists else {
                AppLog.error(.languageID, "loadedWhisperKit: failed after \(Date().timeIntervalSince(start))s: \(error.localizedDescription)")
                throw error
            }
            // Cached folder was stale/corrupt (e.g. partial download) —
            // forget it and fall back to normal resolution once, so a bad
            // entry doesn't permanently block loading when network *is*
            // available.
            AppLog.error(.languageID, "loadedWhisperKit: cached local folder failed to load (\(error.localizedDescription)), retrying via normal resolution")
            UserDefaults.standard.removeObject(forKey: cacheKey)
            let kit = try await WhisperKit(WhisperKitConfig(model: modelName, verbose: false, logLevel: .none))
            cacheModelFolder(from: kit, key: cacheKey)
            whisperKit = kit
            loadedModelName = modelName
            AppLog.info(.languageID, "loadedWhisperKit: ready in \(Date().timeIntervalSince(start))s (after cache-fallback retry)")
            return kit
        }
    }

    private func cacheModelFolder(from kit: WhisperKit, key: String) {
        guard let resolvedFolder = kit.modelFolder?.path else { return }
        UserDefaults.standard.set(resolvedFolder, forKey: key)
        AppLog.debug(.languageID, "loadedWhisperKit: saved local folder for offline reuse: \(resolvedFolder)")
    }

    /// Triggers the model download/load ahead of time, so onboarding can
    /// show a real "downloading" state instead of the first conversation
    /// turn silently stalling on it. Also runs one throwaway inference on
    /// silence: a real device log showed the *first* `detectLangauge` call
    /// taking ~11s (vs. an expected sub-second for a "tiny" model) — almost
    /// certainly CoreML JIT-compiling the model graph on first use, a
    /// known characteristic, not a stuck download. Eating that cost here
    /// means the first real conversation turn isn't the one that pays it.
    func prewarm() async throws {
        let kit = try await loadedWhisperKit()
        AppLog.info(.languageID, "prewarm: running warm-up inference to force any first-call JIT compilation now")
        let start = Date()
        let silence = [Float](repeating: 0, count: WhisperKit.sampleRate) // 1s of silence
        _ = try? await kit.detectLangauge(audioArray: silence)
        AppLog.info(.languageID, "prewarm: warm-up inference took \(Date().timeIntervalSince(start))s")
    }

    /// Returns which of `candidates` WhisperKit's model thinks was spoken
    /// in the clip at `fileURL`, with a confidence renormalized across
    /// just those two candidates — not WhisperKit's full ~100-language
    /// distribution, since we only ever care about a binary choice here —
    /// plus the model's raw absolute confidence in that pick (see
    /// `LanguageIdentificationResult.needsCrossCheck`).
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
        let debugProbs = candidates.map { language -> String in
            let identifier = language.languageCode?.identifier ?? ""
            guard let value = langProbs[identifier] else { return "\(identifier)=missing" }
            return "\(identifier)=\(value)"
        }
        AppLog.info(.languageID, "identify: WhisperKit's top guess=\(topLanguage), full probs (candidates only)=\(debugProbs)")

        // `langProbs` values are LOG-probabilities (≤ 0; 0 means p=1), not
        // linear probabilities — a real device log caught this the hard
        // way: summing them directly (e.g. -0.07 + 0.0) produced a
        // negative "total," which fell through to an arbitrary 50/50
        // tie-break on *every* call, meaning auto-detect was never really
        // detecting anything. A missing candidate (not in WhisperKit's
        // dictionary at all) is treated as effectively impossible
        // (-infinity), not as probability 0 in linear space, which in log
        // space would wrongly mean certainty.
        let rawLogProbs = candidates.map { language -> Double in
            guard let value = langProbs[language.languageCode?.identifier ?? ""] else { return -Double.infinity }
            return Double(value)
        }
        let result = try Self.pickWinner(candidates: candidates, rawLogProbs: rawLogProbs)
        AppLog.info(.languageID, "identify: picked \(result.language.minimalIdentifier) confidence=\(result.confidence) rawLogProb=\(result.rawLogProb) needsCrossCheck=\(result.needsCrossCheck) (took \(Date().timeIntervalSince(start))s)")
        return result
    }

    /// Pure and independently unit-testable: converts `rawLogProbs`
    /// (natural-log probabilities, WhisperKit's native output) to linear
    /// probabilities via a softmax restricted to just the two candidates
    /// the user chose — not WhisperKit's full ~100-language distribution —
    /// and picks the winner. Split out from `identify` so the confidence
    /// math can be verified against fixtures without a device or a loaded
    /// model.
    nonisolated static func pickWinner(candidates: [Locale.Language], rawLogProbs: [Double]) throws -> LanguageIdentificationResult {
        precondition(candidates.count == rawLogProbs.count)

        guard let maxLogProb = rawLogProbs.max(), maxLogProb.isFinite else {
            // No signal for any candidate at all (e.g. silence, or none
            // of them appeared in WhisperKit's output).
            return LanguageIdentificationResult(language: candidates[0], confidence: 1.0 / Double(candidates.count), rawLogProb: -Double.infinity)
        }

        // Softmax, subtracting the max first for numerical stability —
        // standard trick, avoids overflow and keeps the best candidate's
        // term at exp(0) = 1 before normalizing.
        let expValues = rawLogProbs.map { exp($0 - maxLogProb) }
        let total = expValues.reduce(0, +)
        let renormalized = total > 0 ? expValues.map { $0 / total } : candidates.map { _ in 1.0 / Double(candidates.count) }

        guard let bestIndex = renormalized.indices.max(by: { renormalized[$0] < renormalized[$1] }) else {
            throw LanguageIdentifierError.noResult
        }
        return LanguageIdentificationResult(language: candidates[bestIndex], confidence: renormalized[bestIndex], rawLogProb: rawLogProbs[bestIndex])
    }
}
