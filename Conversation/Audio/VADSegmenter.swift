import Foundation
import WhisperKit

/// Emits utterance start/end events so a future manual (push-to-talk)
/// segmentation source could plug into the same controller without any
/// changes downstream.
protocol TurnSegmentationSource: AnyObject {
    var onUtteranceStart: (() -> Void)? { get set }
    var onUtteranceEnd: (() -> Void)? { get set }
}

/// Real-time, streaming voice-activity segmentation: fed small audio
/// buffers as they arrive from the mic, decides when an utterance (one
/// turn) starts and ends via energy + hysteresis, so the app can listen
/// continuously with no push-to-talk button.
///
/// Reuses WhisperKit's `AudioProcessor` energy primitives
/// (`calculateAverageEnergy`, `calculateRelativeEnergy`) instead of
/// reimplementing RMS math, but adds its own streaming state machine and
/// adaptive noise floor on top — WhisperKit's own `EnergyVAD` is built for
/// one-shot batch analysis of a complete waveform, not incremental
/// real-time segmentation of a live mic stream.
///
/// Not `@MainActor`-isolated on purpose: `process(samples:duration:)` runs
/// on `MicrophoneInputManager`'s real-time audio callback, dozens of times
/// a second — cheap enough to call inline without hopping actors. Only the
/// (rare) start/end callbacks need to reach the main actor, and that's the
/// caller's responsibility (see `ConversationLoopController`).
final class VADSegmenter: TurnSegmentationSource {
    struct Config {
        /// Relative energy (0...1, from `AudioProcessor.calculateRelativeEnergy`)
        /// above which a buffer counts as "speech".
        var speechThreshold: Float = 0.18
        /// Consecutive speech time required before declaring utterance
        /// start — debounces brief noise spikes/clicks.
        var minSpeechDuration: TimeInterval = 0.15
        /// Consecutive silence time required, after speech, before
        /// declaring utterance end — long enough to survive a natural
        /// mid-sentence pause, short enough to feel responsive.
        var trailingSilenceDuration: TimeInterval = 0.9
        /// Hard cap so a rambling/stuck utterance can't run forever.
        var maxUtteranceDuration: TimeInterval = 15.0
        /// Exponential-moving-average weight for adapting the noise floor
        /// during silence, so a quieter or noisier environment (still air
        /// vs. a windy walk) doesn't need a fixed hand-tuned threshold.
        var noiseFloorAdaptRate: Float = 0.05

        static let `default` = Config()
    }

    var onUtteranceStart: (() -> Void)?
    var onUtteranceEnd: (() -> Void)?

    private var config: Config
    private enum State { case silence, speech }
    private var state: State = .silence
    private var noiseFloor: Float = 1e-3
    private var speechAccumulated: TimeInterval = 0
    private var silenceAccumulated: TimeInterval = 0
    private var utteranceElapsed: TimeInterval = 0

    init(config: Config = .default) {
        self.config = config
    }

    /// Lets Settings' VAD sensitivity presets take effect on an
    /// already-constructed segmenter, without needing to tear down and
    /// recreate the whole `ConversationLoopController`.
    func updateTrailingSilenceDuration(_ duration: TimeInterval) {
        config.trailingSilenceDuration = duration
    }

    /// Call before starting a fresh listening session.
    func reset() {
        state = .silence
        speechAccumulated = 0
        silenceAccumulated = 0
        utteranceElapsed = 0
    }

    /// Feed one buffer's worth of audio, in chronological order.
    /// `duration` is that buffer's length in seconds.
    func process(samples: [Float], duration: TimeInterval) {
        guard !samples.isEmpty, duration > 0 else { return }
        let energy = AudioProcessor.calculateAverageEnergy(of: samples)
        let relative = AudioProcessor.calculateRelativeEnergy(of: samples, relativeTo: noiseFloor)
        let isSpeech = relative > config.speechThreshold

        switch state {
        case .silence:
            // Only adapt the floor while we believe it's actually quiet —
            // adapting during speech would chase the signal itself.
            noiseFloor += config.noiseFloorAdaptRate * (energy - noiseFloor)
            if isSpeech {
                speechAccumulated += duration
                if speechAccumulated >= config.minSpeechDuration {
                    state = .speech
                    utteranceElapsed = speechAccumulated
                    silenceAccumulated = 0
                    onUtteranceStart?()
                }
            } else {
                speechAccumulated = 0
            }

        case .speech:
            utteranceElapsed += duration
            if isSpeech {
                silenceAccumulated = 0
            } else {
                silenceAccumulated += duration
            }
            if silenceAccumulated >= config.trailingSilenceDuration
                || utteranceElapsed >= config.maxUtteranceDuration {
                state = .silence
                speechAccumulated = 0
                silenceAccumulated = 0
                onUtteranceEnd?()
            }
        }
    }
}
