import XCTest
@testable import Conversation

final class LanguageIdentifierTests: XCTestCase {
    private let en = Locale.Language(identifier: "en")
    private let de = Locale.Language(identifier: "de")

    func testClearWinnerIsConfident() throws {
        // WhisperKit's raw probabilities are a slice of its full
        // ~100-language distribution, so they rarely sum anywhere near 1
        // even for a confident result — renormalization has to happen
        // across just the two candidates for the threshold to mean anything.
        let result = try LanguageIdentifier.pickWinner(candidates: [en, de], rawProbs: [0.62, 0.04])
        XCTAssertEqual(result.language, en)
        XCTAssertEqual(result.confidence, 0.62 / 0.66, accuracy: 0.0001)
        XCTAssertTrue(result.isConfident)
    }

    func testAmbiguousResultIsNotConfident() throws {
        let result = try LanguageIdentifier.pickWinner(candidates: [en, de], rawProbs: [0.30, 0.28])
        XCTAssertFalse(result.isConfident, "renormalized confidence (~0.517) should sit below the reject threshold")
    }

    func testZeroProbabilitiesFallBackToEvenSplitNotConfident() throws {
        // e.g. silence, or a third language neither candidate matches.
        let result = try LanguageIdentifier.pickWinner(candidates: [en, de], rawProbs: [0, 0])
        XCTAssertEqual(result.confidence, 0.5, accuracy: 0.0001)
        XCTAssertFalse(result.isConfident)
    }

    func testGermanCanWinToo() throws {
        let result = try LanguageIdentifier.pickWinner(candidates: [en, de], rawProbs: [0.05, 0.55])
        XCTAssertEqual(result.language, de)
        XCTAssertTrue(result.isConfident)
    }
}
