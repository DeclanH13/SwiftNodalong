import XCTest
@testable import NodalongKit

final class AlbumEditionGroupingTests: XCTestCase {

    private func album(
        id: String,
        name: String,
        artist: String = "Just Mustard",
        tracks: Int = 10,
        explicit: Bool = false
    ) -> AlbumResult {
        AlbumResult(
            id: id, name: name, artistName: artist, artwork: "",
            releaseDate: "2025-01-01", totalTracks: tracks,
            sourceService: .appleMusic, isExplicit: explicit
        )
    }

    // --- canonicalAlbumTitle ---

    func testCanonicalAlbumTitleStripsExplicitSuffix() {
        XCTAssertEqual(canonicalAlbumTitle("We Were Just Here (Explicit)"), "we were just here")
    }

    func testCanonicalAlbumTitleStripsDeluxeSuffix() {
        XCTAssertEqual(canonicalAlbumTitle("We Were Just Here (Deluxe Edition)"), "we were just here")
    }

    func testCanonicalAlbumTitleStripsDashRemaster() {
        XCTAssertEqual(canonicalAlbumTitle("Late Registration - Remastered 2011"), "late registration")
    }

    func testCanonicalAlbumTitleUnchangedForPlainTitle() {
        XCTAssertEqual(canonicalAlbumTitle("We Were Just Here"), "we were just here")
    }

    // --- albumEditionLabel ---

    func testAlbumEditionLabelExtractsDeluxe() {
        XCTAssertEqual(albumEditionLabel("We Were Just Here (Deluxe Edition)"), "Deluxe Edition")
    }

    func testAlbumEditionLabelNilForPlainTitle() {
        XCTAssertNil(albumEditionLabel("We Were Just Here"))
    }

    // --- dedupeAlbumEditions ---

    func testDedupePassesThroughSingleAlbumUnchanged() {
        let a = album(id: "1", name: "We Were Just Here")
        let result = dedupeAlbumEditions([a])
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result[0].alternates.isEmpty)
    }

    func testDedupePrefersExplicitAsPrimary() {
        let clean = album(id: "1", name: "We Were Just Here", explicit: false)
        let explicit = album(id: "2", name: "We Were Just Here", explicit: true)
        let result = dedupeAlbumEditions([clean, explicit])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].id, "2")
        XCTAssertTrue(result[0].isExplicit)
        XCTAssertEqual(result[0].alternates.count, 1)
        XCTAssertEqual(result[0].alternates[0].id, "1")
        XCTAssertEqual(result[0].alternates[0].editionLabel, "Clean")
    }

    func testDedupeLabelsExplicitBracketedTitleDeluxe() {
        let standard = album(id: "1", name: "We Were Just Here", explicit: true)
        let deluxe = album(id: "2", name: "We Were Just Here (Deluxe Edition)", explicit: true)
        let result = dedupeAlbumEditions([standard, deluxe])
        XCTAssertEqual(result.count, 1)
        // Same explicit-ness — deluxe has no extra tracks specified here, so
        // insertion order breaks the tie: standard (seen first) stays primary.
        XCTAssertEqual(result[0].id, "1")
        XCTAssertEqual(result[0].alternates.first?.editionLabel, "Deluxe Edition")
    }

    func testDedupePrefersMoreTracksWhenExplicitnessTies() {
        let standard = album(id: "1", name: "We Were Just Here", tracks: 10, explicit: true)
        let deluxe = album(id: "2", name: "We Were Just Here (Deluxe Edition)", tracks: 14, explicit: true)
        let result = dedupeAlbumEditions([standard, deluxe])
        XCTAssertEqual(result[0].id, "2")
        XCTAssertEqual(result[0].totalTracks, 14)
        XCTAssertEqual(result[0].alternates.first?.id, "1")
    }

    func testDedupeLeavesDifferentAlbumsSeparate() {
        let a = album(id: "1", name: "We Were Just Here")
        let b = album(id: "2", name: "Heart Under")
        let result = dedupeAlbumEditions([a, b])
        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result.allSatisfy { $0.alternates.isEmpty })
    }

    func testDedupeKeepsGroupOrderStableAcrossArtists() {
        let a1 = album(id: "1", name: "Album A", artist: "Artist One")
        let b1 = album(id: "2", name: "Album A", artist: "Artist Two")
        let result = dedupeAlbumEditions([a1, b1])
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].id, "1")
        XCTAssertEqual(result[1].id, "2")
    }

    func testDedupeAlternatesNeverNestFurther() {
        let clean = album(id: "1", name: "We Were Just Here", explicit: false)
        let explicit = album(id: "2", name: "We Were Just Here", explicit: true)
        let result = dedupeAlbumEditions([clean, explicit])
        XCTAssertTrue(result[0].alternates[0].alternates.isEmpty)
    }
}
