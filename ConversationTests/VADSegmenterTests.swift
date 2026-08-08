import XCTest
@testable import Conversation

final class VADSegmenterTests: XCTestCase {
    /// 100ms buffers at a nominal rate — VADSegmenter only cares about
    /// relative energy and elapsed durations, not the actual sample rate.
    private let bufferDuration: TimeInterval = 0.1

    private func silentBuffer(count: Int = 1600) -> [Float] {
        // Tiny noise floor, not dead silence — closer to a real mic.
        (0..<count).map { _ in Float.random(in: -0.001...0.001) }
    }

    private func loudBuffer(count: Int = 1600) -> [Float] {
        (0..<count).map { i in Float(sin(Double(i) * 0.1)) * 0.5 }
    }

    func testStaysIdleOnContinuousSilence() {
        let vad = VADSegmenter()
        var starts = 0, ends = 0
        vad.onUtteranceStart = { starts += 1 }
        vad.onUtteranceEnd = { ends += 1 }

        for _ in 0..<20 {
            vad.process(samples: silentBuffer(), duration: bufferDuration)
        }

        XCTAssertEqual(starts, 0)
        XCTAssertEqual(ends, 0)
    }

    func testDetectsUtteranceStartAndEnd() {
        let vad = VADSegmenter()
        var starts = 0, ends = 0
        vad.onUtteranceStart = { starts += 1 }
        vad.onUtteranceEnd = { ends += 1 }

        // Warm up the noise floor with a bit of silence first.
        for _ in 0..<5 { vad.process(samples: silentBuffer(), duration: bufferDuration) }
        // ~1s of speech — comfortably over minSpeechDuration.
        for _ in 0..<10 { vad.process(samples: loudBuffer(), duration: bufferDuration) }
        XCTAssertEqual(starts, 1, "should declare start after minSpeechDuration of loud audio")
        XCTAssertEqual(ends, 0, "should still be capturing, no trailing silence yet")

        // ~1.2s of trailing silence — comfortably over trailingSilenceDuration (0.9s default).
        for _ in 0..<12 { vad.process(samples: silentBuffer(), duration: bufferDuration) }
        XCTAssertEqual(ends, 1, "should declare end after trailingSilenceDuration of silence")
    }

    func testBriefNoiseSpikeDoesNotTriggerStart() {
        let vad = VADSegmenter()
        var starts = 0
        vad.onUtteranceStart = { starts += 1 }

        for _ in 0..<5 { vad.process(samples: silentBuffer(), duration: bufferDuration) }
        // One single loud buffer (0.1s) is below minSpeechDuration (0.15s default).
        vad.process(samples: loudBuffer(), duration: bufferDuration)
        vad.process(samples: silentBuffer(), duration: bufferDuration)

        XCTAssertEqual(starts, 0, "a single short spike shouldn't be enough to declare speech")
    }

    func testBriefMidSentencePauseDoesNotEndUtterance() {
        let vad = VADSegmenter()
        var starts = 0, ends = 0
        vad.onUtteranceStart = { starts += 1 }
        vad.onUtteranceEnd = { ends += 1 }

        for _ in 0..<5 { vad.process(samples: silentBuffer(), duration: bufferDuration) }
        for _ in 0..<10 { vad.process(samples: loudBuffer(), duration: bufferDuration) }
        XCTAssertEqual(starts, 1)

        // Brief pause (0.3s), well under trailingSilenceDuration (0.9s) — a
        // natural gap between words/clauses shouldn't end the turn.
        for _ in 0..<3 { vad.process(samples: silentBuffer(), duration: bufferDuration) }
        XCTAssertEqual(ends, 0, "a brief mid-sentence pause shouldn't end the utterance")

        // Resume speaking, then really stop.
        for _ in 0..<5 { vad.process(samples: loudBuffer(), duration: bufferDuration) }
        for _ in 0..<12 { vad.process(samples: silentBuffer(), duration: bufferDuration) }
        XCTAssertEqual(ends, 1)
    }

    func testMaxUtteranceDurationForcesEnd() {
        let config = VADSegmenter.Config(maxUtteranceDuration: 1.0)
        let vad = VADSegmenter(config: config)
        var ends = 0
        vad.onUtteranceEnd = { ends += 1 }

        for _ in 0..<5 { vad.process(samples: silentBuffer(), duration: bufferDuration) }
        // Keep talking continuously well past the 1s cap, no silence at all.
        for _ in 0..<20 { vad.process(samples: loudBuffer(), duration: bufferDuration) }

        XCTAssertEqual(ends, 1, "a rambling utterance with no pause should still be force-ended")
    }
}
