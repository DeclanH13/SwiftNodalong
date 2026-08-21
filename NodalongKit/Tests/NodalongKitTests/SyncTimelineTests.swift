import XCTest
@testable import NodalongKit

final class SyncTimelineTests: XCTestCase {

    func testPausedHoldsPosition() {
        let t = SyncTimeline(catalogId: "c", positionMs: 45_000, isPlaying: false, serverUpdatedAt: 1_000)
        // Regardless of how much server time has passed, a paused broadcaster's
        // position doesn't advance.
        XCTAssertEqual(t.targetPositionMs(serverNowMs: 99_000), 45_000)
    }

    func testPlayingExtrapolatesByElapsedServerTime() {
        let t = SyncTimeline(catalogId: "c", positionMs: 45_000, isPlaying: true, serverUpdatedAt: 1_000)
        // 5s later on the server clock → position advanced 5000ms.
        XCTAssertEqual(t.targetPositionMs(serverNowMs: 6_000), 50_000)
    }

    func testClampsToZero() {
        // A follower whose read of "now" is slightly behind the stamp shouldn't
        // seek before the track start.
        let t = SyncTimeline(catalogId: "c", positionMs: 0, isPlaying: true, serverUpdatedAt: 10_000)
        XCTAssertEqual(t.targetPositionMs(serverNowMs: 9_000), 0)
    }

    func testStartOfTrackExtrapolation() {
        // Broadcaster started a track (position 0) two minutes ago; a fresh
        // tune-in should land ~120s in from a single sample.
        let t = SyncTimeline(catalogId: "c", positionMs: 0, isPlaying: true, serverUpdatedAt: 1_000_000)
        XCTAssertEqual(t.targetPositionMs(serverNowMs: 1_120_000), 120_000)
    }
}
