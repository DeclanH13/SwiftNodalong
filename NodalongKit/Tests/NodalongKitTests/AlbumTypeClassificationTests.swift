import XCTest
@testable import NodalongKit

final class AlbumTypeClassificationTests: XCTestCase {

    func testDetectsParentheticalFeat() {
        XCTAssertTrue(titleIndicatesSingleOrEP("Trouble (feat. Childish Gambino)"))
    }

    func testDetectsParentheticalFt() {
        XCTAssertTrue(titleIndicatesSingleOrEP("Trouble (ft. Childish Gambino)"))
    }

    func testDetectsParentheticalFeaturing() {
        XCTAssertTrue(titleIndicatesSingleOrEP("Trouble (featuring Childish Gambino)"))
    }

    func testDetectsBracketedWith() {
        XCTAssertTrue(titleIndicatesSingleOrEP("Trouble [with Childish Gambino]"))
    }

    func testCaseInsensitiveFeat() {
        XCTAssertTrue(titleIndicatesSingleOrEP("Trouble (FEAT. Childish Gambino)"))
    }

    func testDetectsTrailingSingleSuffix() {
        XCTAssertTrue(titleIndicatesSingleOrEP("Summer Pack - Single"))
    }

    func testDetectsTrailingEPSuffix() {
        XCTAssertTrue(titleIndicatesSingleOrEP("Swarm - EP"))
    }

    func testTrailingSuffixCaseInsensitive() {
        XCTAssertTrue(titleIndicatesSingleOrEP("Summer Pack - single"))
    }

    func testPlainAlbumTitleUnaffected() {
        XCTAssertFalse(titleIndicatesSingleOrEP("Because the Internet"))
    }

    func testDoesNotFalsePositiveOnBareWith() {
        // "with" appearing outside a bracketed credit shouldn't trigger —
        // only a "(with ..." / "[with ..." credit pattern should.
        XCTAssertFalse(titleIndicatesSingleOrEP("Kids See Ghosts"))
        XCTAssertFalse(titleIndicatesSingleOrEP("Walk with Me"))
    }

    func testDoesNotFalsePositiveOnUnrelatedParenthetical() {
        XCTAssertFalse(titleIndicatesSingleOrEP("Awaken, My Love! (Bonus Track Version)"))
    }

    func testDoesNotFalsePositiveOnMidTitleHyphen() {
        // "single"/"ep" only counts as a release-type label when it's the
        // trailing suffix, not merely a hyphen appearing mid-title.
        XCTAssertFalse(titleIndicatesSingleOrEP("Single - Ready to Mingle"))
    }
}
