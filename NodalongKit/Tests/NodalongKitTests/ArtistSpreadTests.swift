import XCTest
@testable import NodalongKit

final class ArtistSpreadTests: XCTestCase {
    private func spread(_ a: [String]) -> [String] { spreadByArtist(a, artist: { $0.components(separatedBy: ":")[0] }) }

    func testAdjacentSameArtistIsSeparated() {
        let out = spread(["A:1", "A:2", "B:1", "C:1", "D:1", "E:1", "F:1"])
        let idx = out.enumerated().filter { $0.element.hasPrefix("A") }.map(\.offset)
        XCTAssertGreaterThanOrEqual(idx[1] - idx[0], 4)
        XCTAssertEqual(out.first, "A:1")
    }
    func testUnchangedWhenNoRepeats() {
        let a = ["A:1", "B:1", "C:1", "D:1"]
        XCTAssertEqual(spread(a), a)
    }
    func testIsPermutation() {
        let a = ["A:1", "A:2", "B:1", "B:2", "C:1", "C:2", "D:1"]
        XCTAssertEqual(spread(a).sorted(), a.sorted())
    }
    func testFeaturedCreditCountsAsSameArtist() {
        let items = [("Drake", 1), ("Drake, Future", 2), ("X", 3), ("Y", 4), ("Z", 5), ("W", 6)]
        let out = spreadByArtist(items, artist: { $0.0 })
        let idx = out.enumerated().filter { $0.element.0.hasPrefix("Drake") }.map(\.offset)
        XCTAssertGreaterThanOrEqual(idx[1] - idx[0], 2)
    }
    func testAllSameArtistKeepsEverything() {
        XCTAssertEqual(spread(["A:1", "A:2", "A:3"]).count, 3)
    }
}
