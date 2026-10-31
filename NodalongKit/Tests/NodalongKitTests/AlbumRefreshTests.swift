import XCTest
@testable import NodalongKit

final class AlbumRefreshTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-10-16T09:00:00Z")!

    func testFullyPlayableNeverRefreshes() {
        XCTAssertNil(albumRefreshAfter(releaseDate: "2026-10-16", hasUnplayable: false, now: now))
    }
    func testFutureReleaseWaitsForTheDate() {
        let d = albumRefreshAfter(releaseDate: "2026-11-01", hasUnplayable: true, now: now)
        XCTAssertNotNil(d)
        XCTAssertGreaterThan(d!, now.addingTimeInterval(3_600))
    }
    func testPastReleaseStillIncompleteRetriesHourly() {
        XCTAssertEqual(albumRefreshAfter(releaseDate: "2026-10-10", hasUnplayable: true, now: now), now.addingTimeInterval(3_600))
    }
    func testLongPastReleaseStillIncompleteGivesUp() {
        XCTAssertNil(albumRefreshAfter(releaseDate: "2026-09-01", hasUnplayable: true, now: now))
    }
    func testUnknownDateRetriesInSixHours() {
        XCTAssertEqual(albumRefreshAfter(releaseDate: nil, hasUnplayable: true, now: now), now.addingTimeInterval(6 * 3_600))
        XCTAssertEqual(albumRefreshAfter(releaseDate: "garbage", hasUnplayable: true, now: now), now.addingTimeInterval(6 * 3_600))
    }
}
