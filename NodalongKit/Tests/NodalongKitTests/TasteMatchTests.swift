import XCTest
@testable import NodalongKit

final class TasteMatchTests: XCTestCase {
    private func profile(_ artists: [String]) -> TasteProfile {
        var p = TasteProfile()
        for a in artists { p.add(catalogId: nil, artist: a) }
        return p
    }

    func testNoOverlapIsNil() {
        XCTAssertNil(tasteMatch(mine: profile(["A"]), theirs: profile(["B"])))
    }

    func testSharedArtistsIgnoreCaseAndFeaturedCredits() {
        let m = tasteMatch(mine: profile(["Dahi"]), theirs: profile(["dahi & Childish Gambino"]))
        XCTAssertEqual(m?.sharedArtists, ["dahi"])
    }

    func testDisplayNameComesFromTheirSide() {
        let m = tasteMatch(mine: profile(["fontaines d.c."]), theirs: profile(["Fontaines D.C."]))
        XCTAssertEqual(m?.sharedArtists, ["Fontaines D.C."])
    }

    func testBands() {
        let names = (0..<8).map { "Artist\($0)" }
        XCTAssertEqual(tasteMatch(mine: profile(names), theirs: profile(names))?.band, .strong)
        XCTAssertEqual(tasteMatch(mine: profile(Array(names[0..<3])), theirs: profile(names))?.band, .some)
        XCTAssertEqual(tasteMatch(mine: profile(Array(names[0..<2])), theirs: profile(names))?.band, .little)
    }

    func testEqualityIgnoresDisplayNames() {
        XCTAssertEqual(profile(["ABBA"]), profile(["abba"]))
    }
}
