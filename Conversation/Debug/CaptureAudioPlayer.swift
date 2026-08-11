import AVFoundation

#if DEBUG
/// Minimal playback helper for `CaptureDetailView`.
///
/// Forces the shared `AVAudioSession` into `.playback` before playing,
/// same as the rest of the app's real audio output (`AudioSessionManager.
/// activateSpeaking()`, `AudioCueService`'s earcons) — **not** doing this
/// was the original version's bug: it left the category whatever it
/// already happened to be, which on a debug page opened from Settings
/// with no conversation running is iOS's default `.soloAmbient`, and that
/// category respects the physical ring/silent switch. Clips played back
/// silently with no error and no indication why (a real report: "can't
/// hear anything, even for successfully translated stuff") — the
/// recording/transcription pipeline was never the problem, playback
/// through the wrong session category was.
///
/// Skipped only when the session is already `.playAndRecord` — the one
/// state where `MicrophoneInputManager`'s engine could have a live input
/// tap open, and switching category out from under that produced a real
/// on-device `OSStatus '!pri'` failure elsewhere in this app (see its doc
/// comment). That means opening this page mid-conversation and hitting
/// Play may still be silent under the silent switch — an acceptable
/// trade-off for a debug tool, since forcing the category there risks a
/// worse failure (breaking the live session's mic) for the sake of a
/// clip you can re-open once the session's stopped anyway.
@MainActor
final class CaptureAudioPlayer: NSObject, ObservableObject {
    @Published private(set) var isPlaying = false
    private var player: AVAudioPlayer?
    /// Whether `play()` itself activated the session — only then is it
    /// `stop()`'s job to deactivate it again; leave a session someone
    /// else (e.g. a live conversation) already owns strictly alone.
    private var activatedSessionOurselves = false

    func play(url: URL) {
        stop()

        let session = AVAudioSession.sharedInstance()
        if session.category != .playAndRecord {
            do {
                try session.setCategory(.playback)
                try session.setActive(true)
                activatedSessionOurselves = true
            } catch {
                AppLog.error(.debugCapture, "CaptureAudioPlayer.play: failed to activate playback session: \(error.localizedDescription)")
                // Fall through and try anyway — better to attempt
                // playback through whatever category is active than to
                // silently give up.
            }
        } else {
            AppLog.debug(.debugCapture, "CaptureAudioPlayer.play: session already .playAndRecord (live conversation?), not touching category")
        }

        do {
            let newPlayer = try AVAudioPlayer(contentsOf: url)
            newPlayer.delegate = self
            player = newPlayer
            isPlaying = newPlayer.play()
        } catch {
            AppLog.error(.debugCapture, "CaptureAudioPlayer.play: failed to load \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
        if activatedSessionOurselves {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            activatedSessionOurselves = false
        }
    }
}

extension CaptureAudioPlayer: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.stop()
        }
    }
}
#endif
