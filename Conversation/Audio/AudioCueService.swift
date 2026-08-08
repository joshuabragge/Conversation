import AVFoundation

/// Plays short earcons at turn-state transitions so the app is usable
/// eyes-free while walking.
///
/// Originally used `AudioServicesPlaySystemSound`, which turned out to be
/// silent for real users: those play through the phone's ringer/alert
/// path and get muted by the physical ring/silent switch, unlike audio
/// routed through the app's own `AVAudioSession` (which is how TTS output
/// was already working fine). Switched to a tiny in-memory generated tone
/// played via `AVAudioPlayer` through the app's active session instead —
/// same mechanism as TTS, so it's audible under the same conditions TTS is.
enum AudioCueService {
    private static let enabledKey = "com.joshuabragge.Conversation.audioCuesEnabled"

    /// Settings' on/off toggle. Persisted directly here (rather than
    /// through `AppState`) since it's a leaf preference nothing else needs
    /// to react to.
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    // Retained while playing; AVAudioPlayer doesn't retain itself.
    private static var activePlayers: [AVAudioPlayer] = []

    /// Mic just came down, language-ID/transcription/translation starting.
    static func playProcessing() {
        play(frequency: 880, duration: 0.12)
    }

    /// TTS finished, about to switch back to Listening.
    static func playBackToListening() {
        play(frequency: 660, duration: 0.12)
    }

    /// Confidence too low on both languages — turn discarded.
    static func playRejected() {
        play(frequency: 220, duration: 0.25)
    }

    private static func play(frequency: Double, duration: Double) {
        guard isEnabled else { return }
        let data = ToneGenerator.wavData(frequency: frequency, duration: duration)
        guard let player = try? AVAudioPlayer(data: data) else { return }
        player.volume = 0.6
        activePlayers.append(player)
        player.play()
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.3) {
            activePlayers.removeAll { $0 === player }
        }
    }
}
