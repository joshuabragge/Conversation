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
    /// Settings' voice picker — `AVSpeechSynthesisVoice.speechVoices()` is,
    /// per Apple's own contract, exactly "voices installed by the OS or
    /// downloaded by the user," so this is already what it sounds like it
    /// should be. Sorted with the system's own default voice for this
    /// language first (matching what you'd hear elsewhere on the device,
    /// e.g. VoiceOver), rather than `speechVoices()`'s unspecified order.
    func availableVoices(for language: Locale.Language) -> [AVSpeechSynthesisVoice] {
        let code = language.minimalIdentifier
        let matches = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(code) }
        let systemDefaultID = AVSpeechSynthesisVoice(language: code)?.identifier
        return matches.sorted { a, b in
            if a.identifier == systemDefaultID { return true }
            if b.identifier == systemDefaultID { return false }
            return a.name < b.name
        }
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

extension AVSpeechSynthesisVoice {
    /// For distinguishing same-named voices at different quality tiers in
    /// the picker (e.g. a default "Anna" vs. an Enhanced "Anna" you
    /// specifically downloaded) — otherwise indistinguishable in the UI.
    var qualityLabel: String {
        switch quality {
        case .premium: return "Premium"
        case .enhanced: return "Enhanced"
        case .default: return "Standard"
        @unknown default: return "Standard"
        }
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
