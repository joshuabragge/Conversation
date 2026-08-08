import AVFoundation

enum SpeechOutputError: LocalizedError {
    case noVoiceAvailable(Locale.Language)

    var errorDescription: String? {
        switch self {
        case .noVoiceAvailable(let language):
            return "No voice installed for \(language.displayName) — add one in Settings > Accessibility > Spoken Content > Voices."
        }
    }
}

/// Wraps `AVSpeechSynthesizer` for per-locale text-to-speech output, with
/// a user-configurable rate and per-language voice override for Settings.
@MainActor
final class SpeechOutputService: NSObject, ObservableObject {
    @Published private(set) var isSpeaking = false
    /// `AVSpeechUtteranceMinimumSpeechRate...MaximumSpeechRate`. Settings
    /// exposes this as a slider; defaults to Apple's normal rate.
    @Published var rate: Float = AVSpeechUtteranceDefaultSpeechRate
    /// Explicit voice identifier per language code (e.g. "de" ->
    /// "com.apple.voice.compact.de-DE.Anna"), set via Settings'
    /// `VoicePickerView`. Falls back to automatic selection when absent.
    @Published var voiceOverrides: [String: String] = [:]

    private let synthesizer = AVSpeechSynthesizer()
    private var continuation: CheckedContinuation<Void, Never>?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// True if at least one installed voice exists for `language`. There is
    /// no programmatic way to install a missing voice — callers should
    /// direct the user to Settings > Accessibility > Spoken Content > Voices.
    func hasVoice(for language: Locale.Language) -> Bool {
        !availableVoices(for: language).isEmpty
    }

    /// All installed voices whose language matches `language`, for
    /// Settings' voice picker.
    func availableVoices(for language: Locale.Language) -> [AVSpeechSynthesisVoice] {
        let code = language.minimalIdentifier
        return AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(code) }
    }

    private func voice(for language: Locale.Language) -> AVSpeechSynthesisVoice? {
        let code = language.minimalIdentifier
        if let overrideID = voiceOverrides[code],
           let overridden = AVSpeechSynthesisVoice.speechVoices().first(where: { $0.identifier == overrideID }) {
            return overridden
        }
        return availableVoices(for: language).first ?? AVSpeechSynthesisVoice(language: code)
    }

    /// Speaks `text` in `language`, suspending until playback finishes.
    ///
    /// Throws rather than silently no-op-ing when no voice is installed —
    /// it used to just `return`, which produced translated text with
    /// dead silence and no way to tell why (see `CLAUDE.md`).
    func speak(_ text: String, language: Locale.Language) async throws {
        AppLog.info(.speechOutput, "speak: \"\(text)\" in \(language.minimalIdentifier), \(availableVoices(for: language).count) voice(s) available")
        guard let voice = voice(for: language) else {
            AppLog.error(.speechOutput, "speak: no voice available for \(language.minimalIdentifier)")
            throw SpeechOutputError.noVoiceAvailable(language)
        }
        AppLog.debug(.speechOutput, "speak: using voice \(voice.identifier) (\(voice.name))")

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = rate

        isSpeaking = true
        let start = Date()
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            synthesizer.speak(utterance)
        }
        AppLog.info(.speechOutput, "speak: finished after \(Date().timeIntervalSince(start))s")
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }
}

extension SpeechOutputService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            isSpeaking = false
            continuation?.resume()
            continuation = nil
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            isSpeaking = false
            continuation?.resume()
            continuation = nil
        }
    }
}
