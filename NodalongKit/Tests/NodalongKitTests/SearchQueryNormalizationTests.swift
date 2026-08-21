import XCTest
@testable import NodalongKit

final class SearchQueryNormalizationTests: XCTestCase {

    // --- stripSearchNoise ---

    func testStripSearchNoiseFeatParenthetical() {
        XCTAssertEqual(stripSearchNoise("Song Title (feat. Drake)"), "Song Title")
    }

    func testStripSearchNoiseFtParenthetical() {
        XCTAssertEqual(stripSearchNoise("Song Title (ft. Drake)"), "Song Title")
    }

    func testStripSearchNoiseWithParenthetical() {
        XCTAssertEqual(stripSearchNoise("Song Title (with Travis Scott)"), "Song Title")
    }

    func testStripSearchNoiseRemasteredParenthetical() {
        XCTAssertEqual(stripSearchNoise("Song Title (Remastered 2011)"), "Song Title")
    }

    func testStripSearchNoiseDeluxeParenthetical() {
        XCTAssertEqual(stripSearchNoise("Song Title (Deluxe Edition)"), "Song Title")
    }

    func testStripSearchNoiseLiveParenthetical() {
        XCTAssertEqual(stripSearchNoise("Song Title (Live at Wembley)"), "Song Title")
    }

    func testStripSearchNoiseExplicitBracket() {
        XCTAssertEqual(stripSearchNoise("Song Title [Explicit]"), "Song Title")
    }

    func testStripSearchNoiseExplicitParenthetical() {
        XCTAssertEqual(stripSearchNoise("Song Title (Explicit)"), "Song Title")
    }

    func testStripSearchNoiseDashRemasterSuffix() {
        XCTAssertEqual(stripSearchNoise("Song Title - Remastered 2011"), "Song Title")
    }

    func testStripSearchNoiseCaseInsensitive() {
        XCTAssertEqual(stripSearchNoise("Song Title (FEAT. Drake)"), "Song Title")
    }

    func testStripSearchNoiseMultipleSuffixes() {
        XCTAssertEqual(stripSearchNoise("Song Title (feat. Drake) (Remastered 2011)"), "Song Title")
    }

    func testStripSearchNoiseCleanTitleUnchanged() {
        XCTAssertEqual(stripSearchNoise("Song Title"), "Song Title")
    }

    // --- primaryArtist ---

    func testPrimaryArtistCommaSeparated() {
        XCTAssertEqual(primaryArtist("Drake, Future"), "Drake")
    }

    func testPrimaryArtistAmpersandSeparated() {
        XCTAssertEqual(primaryArtist("Simon & Garfunkel"), "Simon")
    }

    func testPrimaryArtistFeatSeparated() {
        XCTAssertEqual(primaryArtist("Drake feat. Future"), "Drake")
    }

    func testPrimaryArtistFtSeparated() {
        XCTAssertEqual(primaryArtist("Drake ft. Future"), "Drake")
    }

    func testPrimaryArtistFeaturingSeparated() {
        XCTAssertEqual(primaryArtist("Drake featuring Future"), "Drake")
    }

    func testPrimaryArtistWithSeparated() {
        XCTAssertEqual(primaryArtist("Drake with Future"), "Drake")
    }

    func testPrimaryArtistCaseInsensitiveSeparator() {
        XCTAssertEqual(primaryArtist("Drake FEAT. Future"), "Drake")
    }

    func testPrimaryArtistSingleArtistUnchanged() {
        XCTAssertEqual(primaryArtist("Drake"), "Drake")
    }
}
