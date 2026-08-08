import XCTest
@testable import Conversation

final class LanguageIdentifierTests: XCTestCase {
    private let en = Locale.Language(identifier: "en")
    private let de = Locale.Language(identifier: "de")

    // `rawLogProbs` are natural-log probabilities (≤ 0; 0 means p=1), the
    // actual format WhisperKit's `detectLangauge` returns — a real device
    // log caught that the original implementation treated these as linear
    // probabilities instead, which produced a nonsensical negative sum on
    // real data and silently fell back to a coin-flip on every call.

    func testClearWinnerIsConfident() throws {
        // en much more likely than de: log(0.93) ≈ -0.07, log(0.03) ≈ -3.5
        let result = try LanguageIdentifier.pickWinner(candidates: [en, de], rawLogProbs: [-0.07, -3.5])
        XCTAssertEqual(result.language, en)
        XCTAssertTrue(result.isConfident)
        XCTAssertGreaterThan(result.confidence, 0.9)
        XCTAssertFalse(result.needsCrossCheck, "strong absolute confidence shouldn't need a cross-check")
    }

    func testAmbiguousResultIsNotConfident() throws {
        // Nearly equal log-probs -> nearly 50/50 after softmax.
        let result = try LanguageIdentifier.pickWinner(candidates: [en, de], rawLogProbs: [-1.0, -1.05])
        XCTAssertFalse(result.isConfident, "confidence close to 0.5 should sit below the reject threshold")
    }

    func testMissingCandidateTreatedAsEffectivelyImpossible() throws {
        // "de" absent from WhisperKit's dictionary entirely (not a log(1)=0
        // certainty, which `-Double.infinity` correctly avoids implying).
        let result = try LanguageIdentifier.pickWinner(candidates: [en, de], rawLogProbs: [-0.07, -Double.infinity])
        XCTAssertEqual(result.language, en)
        XCTAssertEqual(result.confidence, 1.0, accuracy: 0.0001)
    }

    func testBothMissingFallsBackToEvenSplitNotConfident() throws {
        // e.g. silence, or neither candidate appeared at all.
        let result = try LanguageIdentifier.pickWinner(candidates: [en, de], rawLogProbs: [-Double.infinity, -Double.infinity])
        XCTAssertEqual(result.confidence, 0.5, accuracy: 0.0001)
        XCTAssertFalse(result.isConfident)
    }

    func testGermanCanWinToo() throws {
        let result = try LanguageIdentifier.pickWinner(candidates: [en, de], rawLogProbs: [-4.0, -0.05])
        XCTAssertEqual(result.language, de)
        XCTAssertTrue(result.isConfident)
    }

    func testRealDeviceLogValuesNowProduceAConfidentResultButStillNeedCrossCheck() throws {
        // The actual values from the device logs that exposed both bugs:
        // WhisperKit said "en" (relative confidence 1.0, since "de" was
        // entirely missing from its output) for audio that was actually
        // spoken German ("heute die sonnenschein"). The relative-confidence
        // fix correctly makes this read as a confident pick (no longer the
        // broken 0.5 coin-flip) -- but the *absolute* log-prob (-0.78) is
        // mediocre (~46% linear), which is exactly what needsCrossCheck
        // exists to catch: trust the relative confidence for gating
        // whether to guess at all, but don't skip a second opinion just
        // because the other candidate happened to be absent.
        let result = try LanguageIdentifier.pickWinner(candidates: [en, de], rawLogProbs: [-0.7775666, -Double.infinity])
        XCTAssertEqual(result.language, en)
        XCTAssertTrue(result.isConfident, "relative confidence should still read as confident")
        XCTAssertTrue(result.needsCrossCheck, "but absolute confidence is mediocre and should trigger a cross-check")
    }

    func testHighAbsoluteConfidenceSkipsCrossCheck() throws {
        let result = try LanguageIdentifier.pickWinner(candidates: [en, de], rawLogProbs: [-0.1, -Double.infinity])
        XCTAssertFalse(result.needsCrossCheck)
    }
}
