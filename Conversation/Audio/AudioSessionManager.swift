import AVFoundation

/// Owns the app's `AVAudioSession` and switches it between two configs that
/// are never held simultaneously — this is the fix for the M3 bug where
/// speech synthesis produced no audio: the session was left in the
/// recording-only `.record` category (no output route at all) for the
/// whole session, so `AVSpeechSynthesizer` had nowhere to play through.
///
/// It's also the key differentiator vs. Google Translate's headphone
/// experience: Bluetooth accessories tend to get pinned to HFP (mono,
/// low-bitrate) for as long as an app's session allows simultaneous
/// record+playback. Since this app's turns are sequential (listen, THEN
/// speak — never both), dropping the record capability entirely while
/// speaking lets AirPods/Bluetooth renegotiate up to A2DP for the TTS
/// output instead of staying pinned to low-quality HFP the whole time.
@MainActor
final class AudioSessionManager: ObservableObject {
    enum State {
        case inactive
        case listening
        case speaking
    }

    @Published private(set) var state: State = .inactive
    @Published private(set) var isHeadphonesConnected = false

    /// Fired when the route drops headphones while previously connected —
    /// `ConversationLoopController` uses this to pause the hands-free loop
    /// rather than have it silently keep listening on the phone's own mic.
    var onHeadphonesDisconnected: (() -> Void)?
    /// Fired around system interruptions (phone calls, Siri, etc.).
    var onInterruptionBegan: (() -> Void)?
    var onInterruptionEnded: (() -> Void)?

    private let session = AVAudioSession.sharedInstance()
    private var notificationsRegistered = false

    init() {
        registerNotifications()
        refreshHeadphoneStatus()
    }

    /// Mic active, no quality-sensitive playback in this state — fine for
    /// a Bluetooth accessory to sit in HFP here.
    func activateListening() throws {
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.allowBluetooth, .defaultToSpeaker])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        state = .listening
    }

    /// Mic inactive — lets Bluetooth renegotiate up to A2DP for higher
    /// quality TTS output than the Listening config's HFP would allow.
    func activateSpeaking() throws {
        try session.setCategory(.playback, mode: .spokenAudio, options: [])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        state = .speaking
    }

    func deactivate() {
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        state = .inactive
    }

    // MARK: - Route / interruption notifications

    private func registerNotifications() {
        guard !notificationsRegistered else { return }
        notificationsRegistered = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(routeChanged),
            name: AVAudioSession.routeChangeNotification, object: session
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(interruption),
            name: AVAudioSession.interruptionNotification, object: session
        )
    }

    @objc private func routeChanged(_ note: Notification) {
        Task { @MainActor in
            let wasConnected = self.isHeadphonesConnected
            self.refreshHeadphoneStatus()
            if wasConnected, !self.isHeadphonesConnected {
                self.onHeadphonesDisconnected?()
            }
        }
    }

    @objc private func interruption(_ note: Notification) {
        guard let info = note.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else { return }
        Task { @MainActor in
            switch type {
            case .began: self.onInterruptionBegan?()
            case .ended: self.onInterruptionEnded?()
            @unknown default: break
            }
        }
    }

    private func refreshHeadphoneStatus() {
        let outputs = session.currentRoute.outputs.map(\.portType)
        isHeadphonesConnected = outputs.contains {
            $0 == .headphones || $0 == .bluetoothA2DP || $0 == .bluetoothHFP || $0 == .bluetoothLE
        }
    }
}
