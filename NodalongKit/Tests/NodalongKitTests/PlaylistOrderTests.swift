import XCTest
@testable import NodalongKit

final class PlaylistOrderTests: XCTestCase {

    func testAppendedFromEmpty() {
        XCTAssertEqual(PlaylistOrder.appended(afterMax: nil), PlaylistOrder.step)
    }

    func testAppendedAfterMax() {
        XCTAssertEqual(PlaylistOrder.appended(afterMax: 2048), 2048 + PlaylistOrder.step)
    }

    func testMidpointBetweenTwo() {
        XCTAssertEqual(PlaylistOrder.midpoint(before: 100, after: 200), 150)
    }

    func testMidpointAtStartAndEnd() {
        // Dropped at the end: after the last item.
        XCTAssertEqual(PlaylistOrder.midpoint(before: 500, after: nil), 500 + PlaylistOrder.step)
        // Dropped at the start: before the first item.
        XCTAssertEqual(PlaylistOrder.midpoint(before: nil, after: 500), 500 - PlaylistOrder.step)
        // Only item in the list.
        XCTAssertEqual(PlaylistOrder.midpoint(before: nil, after: nil), PlaylistOrder.step)
    }

    func testMidpointKeepsItemBetweenNeighbours() {
        let before = 1024.0, after = 2048.0
        let mid = PlaylistOrder.midpoint(before: before, after: after)
        XCTAssertGreaterThan(mid, before)
        XCTAssertLessThan(mid, after)
    }

    func testNeedsRenormalizeFalseForWideGapAndEnds() {
        XCTAssertFalse(PlaylistOrder.needsRenormalize(before: 100, after: 200))
        XCTAssertFalse(PlaylistOrder.needsRenormalize(before: nil, after: 200))
        XCTAssertFalse(PlaylistOrder.needsRenormalize(before: 100, after: nil))
    }

    func testNeedsRenormalizeTrueWhenGapCollapses() {
        // Repeatedly halving the gap between the same neighbours eventually
        // trips the renormalise guard.
        var lo = 0.0, hi = 1.0
        var tripped = false
        for _ in 0..<80 {
            if PlaylistOrder.needsRenormalize(before: lo, after: hi) { tripped = true; break }
            let mid = PlaylistOrder.midpoint(before: lo, after: hi)
            lo = mid   // keep inserting just above lo
        }
        XCTAssertTrue(tripped, "gap between fixed neighbours should eventually need renormalising")
    }

    func testRenormalizedIsEvenlySpacedAndAscending() {
        let orders = PlaylistOrder.renormalized(count: 4)
        XCTAssertEqual(orders, [1, 2, 3, 4].map { Double($0) * PlaylistOrder.step })
        XCTAssertEqual(orders, orders.sorted())
        XCTAssertEqual(PlaylistOrder.renormalized(count: 0), [])
    }
}
