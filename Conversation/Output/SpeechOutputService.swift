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
/// **Background TTS is a long-standing, still-unresolved Apple platform
/// issue, not something specific to this app.** Multiple independent
/// developer forum threads going back to iOS 13 report exactly this:
/// `AVSpeechSynthesizer` produces no audio at all while the app isn't in
/// the foreground (locked screen, another app active), regardless of audio
/// session configuration. Confirmed here two different ways, both of which
/// independently failed to fix it: switching `AudioSessionManager` to stay
/// in `.playAndRecord` instead of `.playback` while backgrounded (ruled out
/// session category), and rendering via `write(_:toBufferCallback:)` to a
/// file played back with `AVAudioPlayer` instead of `speak()`'s live output
/// (ruled out "live playback path specifically"). Both mic capture and
/// `AVAudioPlayer`-based earcons keep working fine under the exact same
/// backgrounded conditions, so this isn't background audio being blocked in
/// general.
///
/// Current approach layers on a workaround reported by other developers
/// hitting the same issue: keep a second, unrelated `AVAudioPlayer` sound
/// actively playing *during* synthesis (`startKeepAliveTone`/
/// `stopKeepAliveTone`), which several report "wakes up" the shared audio
/// render path enough for the synthesizer's own output to come through.
/// This is an informal community workaround for what looks like an Apple
/// bug, not a confirmed mechanism — if it doesn't hold up either, the
/// right move is probably to stop fighting `AVSpeechSynthesizer` in the
/// background and design around the limitation (e.g. queue translations
/// and speak them once the app returns to the foreground) rather than
/// trying a fourth blind technical fix.
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
    private var keepAlivePlayer: AVAudioPlayer?

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

        // See the type's doc comment: keeping a second AVAudioPlayer sound
        // actively playing during synthesis is a community-reported
        // workaround for AVSpeechSynthesizer producing no audio while
        // backgrounded. Stopped before real playback starts, not mixed
        // with it.
        startKeepAliveTone()
        let fileURL: URL
        do {
            fileURL = try await synthesizeToFile(utterance)
        } catch {
            stopKeepAliveTone()
            throw error
        }
        stopKeepAliveTone()

        defer { try? FileManager.default.removeItem(at: fileURL) }
        AppLog.debug(.speechOutput, "speak: synthesized to \(fileURL.lastPathComponent) in \(Date().timeIntervalSince(start))s, playing back")
        try await playFile(at: fileURL)

        AppLog.info(.speechOutput, "speak: finished after \(Date().timeIntervalSince(start))s")
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        stopKeepAliveTone()
        player?.stop()
        playbackContinuation?.resume()
        playbackContinuation = nil
    }

    private func startKeepAliveTone() {
        let data = ToneGenerator.wavData(frequency: 440, duration: 0.5)
        guard let tonePlayer = try? AVAudioPlayer(data: data) else {
            AppLog.error(.speechOutput, "startKeepAliveTone: failed to create player")
            return
        }
        tonePlayer.numberOfLoops = -1
        tonePlayer.volume = 0.03
        keepAlivePlayer = tonePlayer
        tonePlayer.play()
        AppLog.debug(.speechOutput, "startKeepAliveTone: playing")
    }

    private func stopKeepAliveTone() {
        keepAlivePlayer?.stop()
        keepAlivePlayer = nil
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

            // Logged per-buffer (not just start/end) specifically so a
            // future "still silent in background" log capture can show
            // definitively whether synthesis produces *any* data at all
            // while backgrounded, vs. producing data that then fails to
            // play — those point to very different next steps.
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
