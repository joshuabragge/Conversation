import AVFoundation

enum SpeechOutputError: LocalizedError {
    case noVoiceAvailable(Locale.Language)
    case synthesisFailed

    var errorDescription: String? {
        switch self {
        case .noVoiceAvailable(let language):
            return "No voice installed for \(language.displayName) — add one in Settings > Accessibility > Spoken Content > Voices."
        case .synthesisFailed:
            return "Couldn't synthesize speech."
        }
    }
}

/// Wraps `AVSpeechSynthesizer` for per-locale text-to-speech output, with
/// a user-configurable rate and per-language voice override for Settings.
///
/// **Does not use `AVSpeechSynthesizer.speak()`'s live playback.** A real
/// device report: TTS produced no audio at all with the screen locked or
/// another app foregrounded, even after `AudioSessionManager` was fixed to
/// stay in a `.playAndRecord`-compatible category in that case — ruling out
/// audio-session category as the cause, since mic capture and
/// `AVAudioPlayer`-based earcons both kept working under the exact same
/// conditions. That isolates the problem to `AVSpeechSynthesizer`'s live
/// output path specifically being unreliable while backgrounded, a
/// limitation documented informally by other developers, not something an
/// audio session config can fix.
///
/// Workaround: render speech to a file via `write(_:toBufferCallback:)`
/// (which doesn't go through the live playback path) and play that file
/// back with `AVAudioPlayer` — the same mechanism already confirmed to
/// work in the background for earcons. Unverified whether this fully
/// solves it without a device retest, but it's the standard documented
/// workaround for this exact class of problem.
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
    private var player: AVAudioPlayer?
    private var playbackContinuation: CheckedContinuation<Void, Never>?

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
        defer { isSpeaking = false }
        let start = Date()

        let fileURL = try await synthesizeToFile(utterance)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        AppLog.debug(.speechOutput, "speak: synthesized to \(fileURL.lastPathComponent) in \(Date().timeIntervalSince(start))s, playing back")
        try await playFile(at: fileURL)

        AppLog.info(.speechOutput, "speak: finished after \(Date().timeIntervalSince(start))s")
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        player?.stop()
        playbackContinuation?.resume()
        playbackContinuation = nil
    }

    /// Renders `utterance` to a temp audio file via
    /// `AVSpeechSynthesizer.write(_:toBufferCallback:)` rather than
    /// `speak()`'s live playback — see the type's doc comment for why.
    /// The final callback from `write` delivers a zero-length buffer to
    /// signal completion (documented Apple behavior).
    private func synthesizeToFile(_ utterance: AVSpeechUtterance) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("caf")

        return try await withCheckedThrowingContinuation { continuation in
            var audioFile: AVAudioFile?
            var resumed = false
            let finish: (Result<URL, Error>) -> Void = { result in
                guard !resumed else { return }
                resumed = true
                continuation.resume(with: result)
            }

            synthesizer.write(utterance) { buffer in
                guard let pcmBuffer = buffer as? AVAudioPCMBuffer else {
                    finish(.failure(SpeechOutputError.synthesisFailed))
                    return
                }
                if pcmBuffer.frameLength == 0 {
                    // End-of-synthesis marker.
                    finish(audioFile != nil ? .success(url) : .failure(SpeechOutputError.synthesisFailed))
                    return
                }
                do {
                    if audioFile == nil {
                        audioFile = try AVAudioFile(forWriting: url, settings: pcmBuffer.format.settings)
                    }
                    try audioFile?.write(from: pcmBuffer)
                } catch {
                    finish(.failure(error))
                }
            }
        }
    }

    private func playFile(at url: URL) async throws {
        let newPlayer = try AVAudioPlayer(contentsOf: url)
        newPlayer.delegate = self
        player = newPlayer
        await withCheckedContinuation { continuation in
            playbackContinuation = continuation
            newPlayer.play()
        }
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

extension SpeechOutputService: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            playbackContinuation?.resume()
            playbackContinuation = nil
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            AppLog.error(.speechOutput, "playFile: decode error: \(error?.localizedDescription ?? "unknown")")
            playbackContinuation?.resume()
            playbackContinuation = nil
        }
    }
}
