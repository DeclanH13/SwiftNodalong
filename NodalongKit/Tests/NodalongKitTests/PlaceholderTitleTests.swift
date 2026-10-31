import XCTest
@testable import NodalongKit

final class PlaceholderTitleTests: XCTestCase {
    func testDetectsApplePlaceholders() {
        XCTAssertTrue(isPlaceholderTrackTitle("Track 6"))
        XCTAssertTrue(isPlaceholderTrackTitle(" track 11 "))
    }
    func testRealTitlesAreNotPlaceholders() {
        XCTAssertFalse(isPlaceholderTrackTitle("Tongue"))
        XCTAssertFalse(isPlaceholderTrackTitle("Track"))
        XCTAssertFalse(isPlaceholderTrackTitle("Track 6 (Live)"))
        XCTAssertFalse(isPlaceholderTrackTitle("Track Star"))
    }
}
