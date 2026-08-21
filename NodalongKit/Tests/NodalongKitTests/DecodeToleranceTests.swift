import XCTest
@testable import NodalongKit

/// Guards the stale-while-revalidate fast path.
///
/// `AlbumResult`/`ArtistResult`/`PlaylistResult` are persisted to disk inside
/// `HomeSnapshot`. Swift's synthesized `Codable` hard-requires every
/// non-optional key on decode — it does NOT fall back to `init` defaults — so
/// adding a non-optional field silently invalidates every previously-written
/// snapshot. `SnapshotStore.load` swallows that with `try?`, so the failure is
/// invisible: the cache just stops working and every launch becomes a cold
/// network load.
///
/// These tests decode payloads that are MISSING the newer keys, which is
/// exactly the shape an older on-disk snapshot has.
final class DecodeToleranceTests: XCTestCase {

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    // MARK: - AlbumResult

    /// The exact regression: a snapshot written before `isExplicit` and
    /// `alternates` were added must still decode.
    func testAlbumResultDecodesWithoutNewerFields() throws {
        let album = try decode(AlbumResult.self, """
        {
          "id": "123", "key": "album:123", "name": "Donda",
          "artistName": "Kanye West", "artwork": "art.jpg",
          "releaseDate": "2021-08-29", "totalTracks": 27,
          "albumType": "album", "sourceService": "apple_music"
        }
        """)

        XCTAssertEqual(album.id, "123")
        XCTAssertEqual(album.name, "Donda")
        XCTAssertFalse(album.isExplicit)
        XCTAssertNil(album.editionLabel)
        XCTAssertTrue(album.alternates.isEmpty)
    }

    /// Only `id` is genuinely required — everything else defaults.
    func testAlbumResultDecodesFromIdAlone() throws {
        let album = try decode(AlbumResult.self, #"{"id": "abc"}"#)

        XCTAssertEqual(album.id, "abc")
        XCTAssertEqual(album.key, "album:abc")   // recomputed when absent
        XCTAssertEqual(album.albumType, "album")
        XCTAssertEqual(album.sourceService, .appleMusic)
    }

    func testAlbumResultRoundTripsWithAlternates() throws {
        let original = AlbumResult(
            id: "1", name: "A", artistName: "B", artwork: "c.jpg",
            releaseDate: "2020-01-01", totalTracks: 10, sourceService: .appleMusic,
            isExplicit: true, editionLabel: "Deluxe",
            alternates: [AlbumResult(id: "2", name: "A (Clean)", artistName: "B",
                                     artwork: "c.jpg", releaseDate: "2020-01-01",
                                     totalTracks: 10, sourceService: .appleMusic)]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AlbumResult.self, from: data)

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.alternates.count, 1)
        XCTAssertTrue(decoded.isExplicit)
        XCTAssertEqual(decoded.editionLabel, "Deluxe")
    }

    /// An unrecognised `sourceService` must NOT fail the whole decode — that
    /// would silently disable the cache on a future rename.
    func testAlbumResultToleratesUnknownSourceService() throws {
        let album = try decode(AlbumResult.self, """
        {"id": "1", "name": "A", "sourceService": "tidal"}
        """)
        XCTAssertEqual(album.name, "A")
        XCTAssertEqual(album.sourceService, .appleMusic)
    }

    // MARK: - ArtistResult

    func testArtistResultDecodesFromIdAlone() throws {
        let artist = try decode(ArtistResult.self, #"{"id": "xyz"}"#)

        XCTAssertEqual(artist.id, "xyz")
        XCTAssertEqual(artist.key, "artist:xyz")
        XCTAssertEqual(artist.followers, 0)
        XCTAssertEqual(artist.sourceService, .appleMusic)
    }

    func testArtistResultRoundTrips() throws {
        let original = ArtistResult(id: "1", name: "Jamie xx", imageUrl: "i.jpg",
                                    genres: "Electronic", followers: 42,
                                    sourceService: .appleMusic)
        let decoded = try JSONDecoder().decode(
            ArtistResult.self, from: try JSONEncoder().encode(original)
        )
        XCTAssertEqual(decoded, original)
    }

    // MARK: - PlaylistResult

    func testPlaylistResultDecodesFromIdAlone() throws {
        let playlist = try decode(PlaylistResult.self, #"{"id": "pl1"}"#)

        XCTAssertEqual(playlist.id, "pl1")
        XCTAssertEqual(playlist.key, "playlist:pl1")
        XCTAssertEqual(playlist.curatorName, "")
    }

    // MARK: - Song (already tolerant — regression guard)

    func testSongStillDecodesWithoutIsExplicit() throws {
        let song = try decode(Song.self, """
        {
          "id": "1", "title": "T", "artist": "A", "album": "Al",
          "artwork": "art.jpg", "track_id": "1", "uri": "1"
        }
        """)
        XCTAssertEqual(song.id, "1")
        XCTAssertFalse(song.isExplicit)
    }
}
