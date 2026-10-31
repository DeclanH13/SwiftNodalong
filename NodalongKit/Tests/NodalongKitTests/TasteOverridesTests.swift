import XCTest
@testable import NodalongKit

final class TasteOverridesTests: XCTestCase {
    private func doc(_ artist: String, _ genres: [String] = ["Rock"]) -> LibraryTrackDoc {
        LibraryTrackDoc(catalogId: UUID().uuidString, title: "t", artist: artist, album: "a", artwork: "",
                        uri: "", sourceService: .appleMusic, genres: genres, savedAt: 1)
    }

    func testKeyNormalizesFeaturedCredits() {
        var o = TasteOverrides()
        o.block("Dahi & Childish Gambino")
        XCTAssertEqual(o.multiplier(forKey: "dahi"), 0)
    }

    func testBlockAndReduceAreExclusive() {
        var o = TasteOverrides()
        o.reduce("X"); o.block("X")
        XCTAssertTrue(o.reduced.isEmpty); XCTAssertEqual(o.blocked, ["x"])
        o.reduce("X")
        XCTAssertTrue(o.blocked.isEmpty); XCTAssertEqual(o.reduced, ["x"])
        o.clear(key: "x")
        XCTAssertTrue(o.isEmpty)
    }

    func testBlockedArtistIsNotASeedButStaysKnown() {
        var o = TasteOverrides(); o.block("Blocked Band")
        let seeds = buildTasteSeeds(library: [doc("Blocked Band"), doc("Other")], recents: [], spotlights: [],
                                    artistLimit: 10, overrides: o)
        XCTAssertFalse(seeds.artists.contains { $0.key == "blocked band" })
        XCTAssertTrue(seeds.knownArtistKeys.contains("blocked band"))
    }

    func testBlockedArtistNeverListenedToIsStillExcluded() {
        var o = TasteOverrides(); o.block("Isaiah Rashad")
        let seeds = buildTasteSeeds(library: [doc("Other")], recents: [], spotlights: [], overrides: o)
        XCTAssertTrue(seeds.knownArtistKeys.contains("isaiah rashad"))
    }

    func testReducedArtistKeepsAFractionOfItsWeight() {
        var o = TasteOverrides(); o.reduce("Quiet")
        let plain = buildTasteSeeds(library: [doc("Quiet")], recents: [], spotlights: [], artistLimit: 5)
        let reduced = buildTasteSeeds(library: [doc("Quiet")], recents: [], spotlights: [], artistLimit: 5, overrides: o)
        XCTAssertEqual(reduced.artists.first!.weight, plain.artists.first!.weight * TasteOverrides.reducedMultiplier, accuracy: 1e-9)
    }

    func testWeightsApplyingOverrides() {
        var o = TasteOverrides(); o.block("a"); o.reduce("b")
        let w = TasteWeights(artists: ["a": 1, "b": 1, "c": 1]).applying(o)
        XCTAssertEqual(w.artists["b"], TasteOverrides.reducedMultiplier)
        XCTAssertEqual(w.artists["c"], 1)
        XCTAssertTrue(w.blocked.contains("a"))
    }
}
