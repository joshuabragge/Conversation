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

    func testRealDeviceLogValuesNowProduceAConfidentResult() throws {
        // The actual values from the device log that exposed this bug:
        // en=-0.06836422, de missing entirely. Previously produced
        // confidence=0.5 (rejected) via the broken linear-sum fallback;
        // should now correctly recognize this as a confident English call.
        let result = try LanguageIdentifier.pickWinner(candidates: [en, de], rawLogProbs: [-0.06836422, -Double.infinity])
        XCTAssertEqual(result.language, en)
        XCTAssertTrue(result.isConfident)
    }
}
