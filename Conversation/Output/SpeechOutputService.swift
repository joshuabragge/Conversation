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
/// **Deliberately foreground-only.** `AVSpeechSynthesizer` producing no
/// audio at all while the app isn't in the foreground (locked screen,
/// another app active) is a long-standing, unresolved Apple platform issue
/// — multiple independent developer forum threads going back to iOS 13
/// report exactly this, regardless of audio session configuration. Three
/// independent things were tried here and all failed to fix it: keeping
/// `AudioSessionManager` in `.playAndRecord` instead of `.playback` while
/// backgrounded, rendering via `write(_:toBufferCallback:)` to a file
/// played back with `AVAudioPlayer` instead of `speak()`'s live output, and
/// a community-reported "keep a second unrelated `AVAudioPlayer` sound
/// playing during synthesis" workaround. Rather than keep chasing a
/// platform bug, the app no longer declares `UIBackgroundModes: audio` at
/// all (see `project.yml`) and instead keeps the screen awake while a
/// session is running (`ConversationLoopController`) so it never needs to
/// speak while backgrounded in the first place — see CLAUDE.md for the
/// full history if this ever needs revisiting.
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

    /// Dumps every voice `AVSpeechSynthesisVoice.speechVoices()` currently
    /// returns (not filtered to the active language pair) to the Debug
    /// Log — identifier, name, language, quality, and traits. Exists
    /// specifically to answer "why don't Siri's voices show up in the
    /// picker" from a real device rather than from guessing: Apple's own
    /// live Siri assistant voice (and the Enhanced/Premium "Siri Voice 1-4"
    /// options under Settings > Accessibility > Spoken Content > Voices) is
    /// documented, across many Apple Developer Forum threads, as
    /// deliberately withheld from `AVSpeechSynthesizer` — third-party apps
    /// can't get it, to stop an app impersonating Siri. `availableVoices(for:)`
    /// already returns everything `speechVoices()` hands back with no
    /// extra filtering, so if a Siri-branded voice legitimately isn't
    /// appearing, this is a platform restriction, not a bug in that
    /// filter — this dump is how to confirm that on a specific device
    /// instead of taking that on faith. Call from Settings' Voices section
    /// so a Debug Log capture always has a fresh copy.
    func logAvailableVoiceInventory() {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        AppLog.info(.speechOutput, "voice inventory: \(voices.count) total installed voice(s)")
        for voice in voices.sorted(by: { $0.language < $1.language }) {
            let traits = [
                voice.voiceTraits.contains(.isNoveltyVoice) ? "novelty" : nil,
                voice.voiceTraits.contains(.isPersonalVoice) ? "personal" : nil,
            ].compactMap { $0 }.joined(separator: ",")
            AppLog.info(.speechOutput, "voice inventory: \(voice.language) \"\(voice.name)\" (\(voice.qualityLabel)) id=\(voice.identifier)\(traits.isEmpty ? "" : " traits=\(traits)")")
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
            var bufferCount = 0
            var totalFrames: AVAudioFrameCount = 0
            var resumed = false
            let finish: (Result<URL, Error>) -> Void = { result in
                guard !resumed else { return }
                resumed = true
                continuation.resume(with: result)
            }

            // Logged per-buffer (not just start/end) so a Debug Log capture
            // can show whether a stuck `speak()` call (caught by
            // `RecognitionConfig.speechOutputTimeout`) never produced any
            // data at all vs. produced data that then failed to play —
            // those point to very different next steps.
            synthesizer.write(utterance) { buffer in
                guard let pcmBuffer = buffer as? AVAudioPCMBuffer else {
                    AppLog.error(.speechOutput, "synthesizeToFile: write() callback delivered a non-PCM buffer")
                    finish(.failure(SpeechOutputError.synthesisFailed))
                    return
                }
                bufferCount += 1
                if pcmBuffer.frameLength == 0 {
                    // End-of-synthesis marker.
                    AppLog.info(.speechOutput, "synthesizeToFile: done, \(bufferCount) buffer(s), \(totalFrames) total frames")
                    finish(audioFile != nil ? .success(url) : .failure(SpeechOutputError.synthesisFailed))
                    return
                }
                totalFrames += pcmBuffer.frameLength
                do {
                    if audioFile == nil {
                        audioFile = try AVAudioFile(forWriting: url, settings: pcmBuffer.format.settings)
                        AppLog.debug(.speechOutput, "synthesizeToFile: first buffer arrived (\(pcmBuffer.frameLength) frames), file opened")
                    }
                    try audioFile?.write(from: pcmBuffer)
                } catch {
                    AppLog.error(.speechOutput, "synthesizeToFile: write failed on buffer \(bufferCount): \(error.localizedDescription)")
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
