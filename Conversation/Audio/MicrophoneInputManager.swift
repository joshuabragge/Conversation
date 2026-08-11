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
/// turn), so a benign race at the exact boundary of `audioFile` (a buffer
/// or two included/excluded from the recorded clip) is an acceptable
/// trade-off for not paying actor-hop overhead on the hot path.
/// `preRollBuffers` below needs a real lock, not just that same shrug —
/// see its comment.
final class MicrophoneInputManager {
    private let audioEngine = AVAudioEngine()
    private var audioFile: AVAudioFile?
    private var utteranceFileURL: URL?
    private var onBuffer: ((_ samples: [Float], _ duration: TimeInterval) -> Void)?

    /// Rolling buffer of raw audio, always being filled regardless of VAD
    /// state — including during `VADSegmenter`'s `minSpeechDuration`
    /// debounce and `ConversationLoopController`'s post-restart grace
    /// period, neither of which write to `audioFile`. Exists specifically
    /// because a device log showed the first word or two of fast speech
    /// getting dropped: by the time VAD *confirms* speech is happening
    /// and `beginUtteranceFile()` runs, the actual onset already
    /// happened — without a pre-roll, that onset is just gone. ~1s
    /// capacity covers the grace period (0.4s) + debounce (0.15s) with
    /// margin. `beginUtteranceFile()` prepends whatever's in here before
    /// switching to live writes.
    ///
    /// Needs its own lock, unlike `audioFile`/`utteranceFileURL`'s benign
    /// races above: this is a Swift `Array` mutated on the audio thread
    /// (append every ~21ms) while `beginUtteranceFile()` reads it from the
    /// main actor — concurrent array mutation without synchronization is
    /// undefined behavior (potential memory corruption/crash), not just a
    /// stale-value risk.
    private var preRollBuffers: [AVAudioPCMBuffer] = []
    private let preRollLock = NSLock()
    private let preRollCapacity = 50 // ~1.07s at 1024 frames/48kHz

    /// The actual format flowing through the tap right now, read from
    /// each buffer as it arrives (`buffer.format`) rather than queried
    /// separately via `outputFormat(forBus:)` — see `installTapAndStart`'s
    /// doc comment for the real crash a separately-queried format caused.
    /// `beginUtteranceFile` uses this instead of its own independent
    /// query, so the file it opens is guaranteed to match what's actually
    /// written to it. Same benign-race trade-off as `audioFile`/
    /// `utteranceFileURL` above (written on the audio thread, read from
    /// the main actor) — not `preRollBuffers`' problem, since this is a
    /// single reference reassignment, not a mutable collection.
    private var currentFormat: AVAudioFormat?

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
        currentFormat = nil
        preRollLock.lock()
        preRollBuffers.removeAll()
        preRollLock.unlock()
        AppLog.debug(.mic, "stopEngine")
    }

    /// Resumes capture with the callback from the original `startEngine`
    /// call, after a `stopEngine()` done to release the route for a
    /// Speaking-phase audio-session switch. Safe/no-op if never stopped
    /// or if `startEngine` was never called.
    func restartEngine() throws {
        guard !audioEngine.isRunning, onBuffer != nil else {
            AppLog.debug(.mic, "restartEngine: no-op (isRunning=\(audioEngine.isRunning), hasCallback=\(onBuffer != nil))")
            return
        }
        // `AVAudioEngine` node formats can go stale across an
        // `AVAudioSession` category change (the input node's format after
        // returning to `.playAndRecord` isn't guaranteed identical to
        // before it left) — `reset()` before rebuilding the tap is a
        // known mitigation for engines silently failing to actually
        // capture after a route/category change. Unverified whether this
        // was actually needed here vs. just defensive; check the logs
        // from `installTapAndStart` if capture still misbehaves after a
        // Speaking phase.
        audioEngine.reset()
        try installTapAndStart()
        AppLog.info(.mic, "restartEngine: succeeded")
    }

    /// Opens a fresh temp file, immediately writes whatever's in the
    /// pre-roll buffer (the actual onset of speech, captured before VAD
    /// confirmed it), then starts recording the live tap's buffers into
    /// it until `endUtteranceFile()` is called.
    func beginUtteranceFile() {
        // Prefer the actually-observed tap format over a fresh
        // `outputFormat(forBus:)` query — see `installTapAndStart`'s doc
        // comment for why a separately-queried format isn't guaranteed to
        // match hardware, especially right after a Bluetooth route
        // change. A file opened with a format that doesn't match what's
        // actually written to it would fail every `file.write(from:)`
        // silently (see that call's `try?`) rather than crash — a
        // quieter version of the same underlying mismatch. Falls back to
        // a fresh query only in the unexpected case no buffer has
        // arrived yet.
        let format = currentFormat ?? audioEngine.inputNode.outputFormat(forBus: 0)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("caf")
        guard let file = try? AVAudioFile(forWriting: url, settings: format.settings) else {
            audioFile = nil
            utteranceFileURL = nil
            AppLog.error(.mic, "beginUtteranceFile: failed to open \(url.lastPathComponent)")
            return
        }

        preRollLock.lock()
        let preRoll = preRollBuffers
        preRollLock.unlock()
        for buffer in preRoll {
            try? file.write(from: buffer)
        }

        audioFile = file
        utteranceFileURL = url
        AppLog.debug(.mic, "beginUtteranceFile: \(url.lastPathComponent), wrote \(preRoll.count) pre-roll buffer(s)")
    }

    /// Stops recording and returns the file URL, or `nil` if nothing was
    /// captured (e.g. `beginUtteranceFile` failed to open the file).
    func endUtteranceFile() -> URL? {
        defer { audioFile = nil }
        let url = utteranceFileURL
        utteranceFileURL = nil
        AppLog.debug(.mic, "endUtteranceFile: \(url?.lastPathComponent ?? "nil")")
        return url
    }

    private func installTapAndStart() throws {
        let inputNode = audioEngine.inputNode
        // Deliberately `nil`, not a format queried via
        // `outputFormat(forBus:)` a moment earlier and handed back in —
        // that's what caused a real on-device crash
        // ('com.apple.coreaudio.avfaudio', "Failed to create tap due to
        // format mismatch"). Sequence from the crash log: AirPods connect
        // (still in A2DP), `AudioSessionManager.activateListening()`
        // switches the session to `.playAndRecord`, which kicks the
        // accessory into HFP for recording — and *before* that Bluetooth
        // codec renegotiation actually finished, this method queried
        // `outputFormat(forBus:)` and got a stale 48kHz reading. By the
        // time `installTap`'s internal validation ran a beat later, the
        // real hardware format had already settled to HFP's 24kHz, the
        // two didn't match, and passing an explicit format makes that a
        // hard, Swift-uncatchable exception rather than a recoverable
        // error. A longer/differently-timed query doesn't close this
        // race reliably — it's inherent to querying-then-using two
        // separate calls apart while the accessory is still renegotiating.
        // `nil` sidesteps it entirely: the engine resolves the tap's
        // format itself, atomically, against whatever the hardware
        // actually is at that instant — Apple's own recommended pattern
        // for this exact class of crash. The real per-buffer format is
        // read from `buffer.format` below instead (see `currentFormat`).
        AppLog.debug(.mic, "installTapAndStart: hw format=\(inputNode.outputFormat(forBus: 0))")

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            guard let self else { return }
            self.currentFormat = buffer.format

            if let copy = Self.copyBuffer(buffer) {
                self.preRollLock.lock()
                self.preRollBuffers.append(copy)
                if self.preRollBuffers.count > self.preRollCapacity {
                    self.preRollBuffers.removeFirst(self.preRollBuffers.count - self.preRollCapacity)
                }
                self.preRollLock.unlock()
            }

            if self.audioFile != nil {
                try? self.audioFile?.write(from: buffer)
            }
            let duration = buffer.format.sampleRate > 0 ? Double(buffer.frameLength) / buffer.format.sampleRate : 0
            self.onBuffer?(AudioProcessor.convertBufferToArray(buffer: buffer), duration)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
            AppLog.info(.mic, "installTapAndStart: engine running")
        } catch {
            AppLog.error(.mic, "installTapAndStart: engine.start() threw: \(error.localizedDescription)")
            throw error
        }
    }

    /// Deep-copies a tap-provided buffer: Apple's docs are explicit that a
    /// buffer handed to an `AVAudioNodeTapBlock` is only valid for the
    /// duration of that call — retaining it for the pre-roll window
    /// without copying would read memory the engine may have already
    /// reused. Returns `nil` (silently skipping this buffer for pre-roll
    /// purposes) rather than crashing if the format isn't float-based,
    /// which isn't expected here but would otherwise make `floatChannelData`
    /// unavailable.
    private static func copyBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength),
              let src = buffer.floatChannelData, let dst = copy.floatChannelData
        else { return nil }
        copy.frameLength = buffer.frameLength
        for channel in 0..<Int(buffer.format.channelCount) {
            dst[channel].update(from: src[channel], count: Int(buffer.frameLength))
        }
        return copy
    }
}
