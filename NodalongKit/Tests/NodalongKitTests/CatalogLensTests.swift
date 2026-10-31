import XCTest
@testable import NodalongKit

final class CatalogLensTests: XCTestCase {

    private func doc(_ id: String, artist: String, genres: [String], savedAt: Double = 0) -> LibraryTrackDoc {
        LibraryTrackDoc(
            catalogId: id, title: "T\(id)", artist: artist, album: "A", artwork: "", uri: "u\(id)",
            sourceService: .appleMusic, isrc: nil, duration: nil, trackNumber: nil, albumReleaseDate: nil,
            genres: genres, isExplicit: false, savedAt: savedAt
        )
    }

    func testNarrowedSeedsKeepExclusions() {
        let lib = [doc("1", artist: "A", genres: []), doc("2", artist: "B", genres: [])]
        let seeds = buildTasteSeeds(library: lib, recents: [], spotlights: [])
        let narrowed = seeds.narrowedTo(artistKey: "a")
        XCTAssertEqual(narrowed.artists.map(\.key), ["a"])
        XCTAssertTrue(narrowed.knownArtistKeys.contains("b"), "other artists stay excluded")
        XCTAssertEqual(narrowed.heardCatalogIds, seeds.heardCatalogIds)
    }

    func testStrayTagDoesNotMakeAGenreDiscoverable() {
        var lib: [LibraryTrackDoc] = []
        // Three real rock artists.
        for a in ["Floyd", "Genesis", "Eagles"] { for i in 0..<4 { lib.append(doc("\(a)\(i)", artist: a, genres: ["Rock"])) } }
        // A rapper with one stray Rock tag among many Hip-Hop tracks.
        for i in 0..<20 { lib.append(doc("r\(i)", artist: "Rapper", genres: ["Hip-Hop/Rap"])) }
        lib.append(doc("rx", artist: "Rapper", genres: ["Rock"]))
        let names = discoverableGenres(lib).map(\.name)
        XCTAssertTrue(names.contains("Rock"))
        XCTAssertFalse(names.contains("Hip-Hop/Rap"), "one artist is not enough for a genre tile")
    }

    func testGenreNeedsEnoughArtists() {
        let lib = (0..<10).map { doc("\($0)", artist: "Solo", genres: ["Jazz"]) }
        XCTAssertTrue(discoverableGenres(lib).isEmpty)
        XCTAssertEqual(discoverableGenres(lib, minArtists: 1).map(\.name), ["Jazz"])
    }

    func testRecentReleaseBoundaries() {
        let now = ISO8601DateFormatter().date(from: "2026-10-12T12:00:00Z")!
        XCTAssertTrue(isRecentRelease("2026-10-01", withinDays: 60, now: now))
        XCTAssertTrue(isRecentRelease("2026-08-20", withinDays: 60, now: now))
        XCTAssertFalse(isRecentRelease("2026-08-01", withinDays: 60, now: now))
        XCTAssertFalse(isRecentRelease("2026-10-16", withinDays: 60, now: now), "future = not released")
        XCTAssertFalse(isRecentRelease("garbage", withinDays: 60, now: now))
    }

    func testPlaylistDecodesWithAndWithoutVariantAndUnknownLens() throws {
        let withVariant = #"{"ownerUid":"u","title":"t","lens":"becauseArtist","variant":"Kendrick Lamar","source":"generated"}"#.data(using: .utf8)!
        let p = try JSONDecoder().decode(Playlist.self, from: withVariant)
        XCTAssertEqual(p.lens, .becauseArtist)
        XCTAssertEqual(p.variant, "Kendrick Lamar")
        let legacy = #"{"ownerUid":"u","title":"t","lens":"taste","source":"generated"}"#.data(using: .utf8)!
        XCTAssertNil(try JSONDecoder().decode(Playlist.self, from: legacy).variant)
        let future = #"{"ownerUid":"u","title":"t","lens":"somethingNew","source":"generated"}"#.data(using: .utf8)!
        XCTAssertNil(try JSONDecoder().decode(Playlist.self, from: future).lens)
    }
}
