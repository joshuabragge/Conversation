import AVFoundation
import WhisperKit

/// Owns the continuous `AVAudioEngine` mic tap for hands-free listening,
/// and optionally records the buffers flowing through it to a temp file
/// while `ConversationLoopController` believes an utterance is in
/// progress (per `VADSegmenter`'s events).
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

    /// Starts the engine and installs a tap that both forwards
    /// float-sample buffers to `onBuffer` (for VAD) and, if an utterance
    /// file is open, writes the raw buffer to it.
    func startEngine(onBuffer: @escaping (_ samples: [Float], _ duration: TimeInterval) -> Void) throws {
        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            if self?.audioFile != nil {
                try? self?.audioFile?.write(from: buffer)
            }
            let duration = format.sampleRate > 0 ? Double(buffer.frameLength) / format.sampleRate : 0
            onBuffer(AudioProcessor.convertBufferToArray(buffer: buffer), duration)
        }

        audioEngine.prepare()
        try audioEngine.start()
    }

    func stopEngine() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        audioFile = nil
        utteranceFileURL = nil
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
}
