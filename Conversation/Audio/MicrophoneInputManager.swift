import AVFoundation
import WhisperKit

/// Owns the `AVAudioEngine` mic tap for hands-free listening, and
/// optionally records the buffers flowing through it to a temp file while
/// `ConversationLoopController` believes an utterance is in progress (per
/// `VADSegmenter`'s events).
///
/// **Must be fully stopped, not just left running, before the audio
/// session's category changes** (e.g. the Listening → Speaking switch in
/// `AudioSessionManager`). Leaving the input node live across a category
/// change that drops record capability (`.playAndRecord` → `.playback`)
/// produced a real `OSStatus '!pri'` (`AVAudioSessionErrorInsufficientPriority`)
/// error on-device — the engine's I/O unit was still holding the input
/// route when the session tried to reconfigure out from under it. Callers
/// must `stopEngine()` before switching to Speaking and `restartEngine()`
/// after switching back, rather than assuming the engine can just keep
/// running across the whole session the way `VADSegmenter`'s "continuous
/// listening" framing implies.
///
/// Deliberately **not** `@MainActor`-isolated: the tap callback runs on a
/// real-time audio thread, and both the file write and the VAD energy
/// calculation are cheap enough to do inline there without hopping actors
/// on every buffer (this fires dozens of times a second). Only
/// `beginUtteranceFile`/`endUtteranceFile` are called from the main actor,
/// in response to VAD start/end events — those are rare (a few times per
/// turn), so a benign race at the exact boundary (a buffer or two
/// included/excluded from the recorded clip) is an acceptable trade-off
/// for not paying actor-hop overhead on the hot path.
final class MicrophoneInputManager {
    private let audioEngine = AVAudioEngine()
    private var audioFile: AVAudioFile?
    private var utteranceFileURL: URL?
    private var onBuffer: ((_ samples: [Float], _ duration: TimeInterval) -> Void)?

    /// Starts the engine and installs a tap that both forwards
    /// float-sample buffers to `onBuffer` (for VAD) and, if an utterance
    /// file is open, writes the raw buffer to it. Retains `onBuffer` so
    /// `restartEngine()` can resume with the same callback later.
    func startEngine(onBuffer: @escaping (_ samples: [Float], _ duration: TimeInterval) -> Void) throws {
        self.onBuffer = onBuffer
        try installTapAndStart()
    }

    /// Releases the input route entirely — required before switching the
    /// audio session away from a recording-capable category. Safe to call
    /// even if already stopped.
    func stopEngine() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        audioFile = nil
        utteranceFileURL = nil
    }

    /// Resumes capture with the callback from the original `startEngine`
    /// call, after a `stopEngine()` done to release the route for a
    /// Speaking-phase audio-session switch. Safe/no-op if never stopped
    /// or if `startEngine` was never called.
    func restartEngine() throws {
        guard !audioEngine.isRunning, onBuffer != nil else { return }
        try installTapAndStart()
    }

    /// Opens a fresh temp file and starts recording the live tap's buffers
    /// into it, until `endUtteranceFile()` is called.
    func beginUtteranceFile() {
        let format = audioEngine.inputNode.outputFormat(forBus: 0)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("caf")
        audioFile = try? AVAudioFile(forWriting: url, settings: format.settings)
        utteranceFileURL = audioFile != nil ? url : nil
    }

    /// Stops recording and returns the file URL, or `nil` if nothing was
    /// captured (e.g. `beginUtteranceFile` failed to open the file).
    func endUtteranceFile() -> URL? {
        defer { audioFile = nil }
        let url = utteranceFileURL
        utteranceFileURL = nil
        return url
    }

    private func installTapAndStart() throws {
        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            if self?.audioFile != nil {
                try? self?.audioFile?.write(from: buffer)
            }
            let duration = format.sampleRate > 0 ? Double(buffer.frameLength) / format.sampleRate : 0
            self?.onBuffer?(AudioProcessor.convertBufferToArray(buffer: buffer), duration)
        }

        audioEngine.prepare()
        try audioEngine.start()
    }
}
