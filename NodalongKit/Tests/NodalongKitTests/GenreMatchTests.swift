import XCTest
@testable import NodalongKit

final class GenreMatchTests: XCTestCase {
    private func t(_ artist: String, _ genres: [String], times: Int = 1) -> [GenreArtistTrack] {
        Array(repeating: GenreArtistTrack(artist: artist, genres: genres), count: times)
    }

    func testSharedGenreWithSharedArtists() {
        let mine   = t("Kendrick Lamar", ["Hip-Hop/Rap"]) + t("Tyler, the Creator", ["Hip-Hop/Rap"]) + t("Radiohead", ["Alternative"])
        let theirs = t("Kendrick Lamar", ["Hip-Hop/Rap"]) + t("Tyler, the Creator", ["Hip-Hop/Rap"]) + t("Slowdive", ["Alternative"])
        let m = genreTasteMatch(mine: mine, theirs: theirs)
        XCTAssertEqual(m?.overlaps.first?.genre, "Hip-Hop/Rap")
        XCTAssertEqual(m?.overlaps.first?.sharedArtists.count, 2)
        XCTAssertEqual(m?.sharedArtistCount, 2)
    }

    func testNoSharedGenreIsNil() {
        XCTAssertNil(genreTasteMatch(mine: t("A", ["Rock"]), theirs: t("B", ["Jazz"])))
    }

    func testSameGenreButNoSharedArtistIsNil() {
        XCTAssertNil(genreTasteMatch(mine: t("A", ["Rock"]), theirs: t("B", ["Rock"])))
    }

    func testMissingGenreDataIsNil() {
        XCTAssertNil(genreTasteMatch(mine: t("A", []), theirs: t("A", ["Rock"])))
    }

    func testOneOffTagDoesNotCreateAGenre() {
        // 1 of 6 tracks tagged Jazz (< 25%) and not the top tag.
        let mine   = t("Band", ["Rock"], times: 5) + t("Band", ["Jazz"])
        let theirs = t("Band", ["Jazz"])
        XCTAssertNil(genreTasteMatch(mine: mine, theirs: theirs)?.overlaps.first(where: { $0.genre == "Jazz" }))
    }

    func testFeaturedCreditsCollapseToThePrimaryArtist() {
        let m = genreTasteMatch(mine: t("Dahi", ["Hip-Hop/Rap"]), theirs: t("Dahi & Childish Gambino", ["Hip-Hop/Rap"]))
        XCTAssertEqual(m?.sharedArtistCount, 1)
    }

    func testBandThresholds() {
        let names = (0..<8).map { "Artist\($0)" }
        let all = names.flatMap { t($0, ["Rock"]) }
        XCTAssertEqual(genreTasteMatch(mine: all, theirs: all)?.band, .strong)
        XCTAssertEqual(genreTasteMatch(mine: Array(all.prefix(3)), theirs: all)?.band, .some)
        XCTAssertEqual(genreTasteMatch(mine: Array(all.prefix(1)), theirs: all)?.band, .little)
    }
}
