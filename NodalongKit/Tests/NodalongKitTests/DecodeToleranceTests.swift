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

    // MARK: - CatalogTrack / Post — the app-wide-blanking guard

    /// 🔴 THE regression this whole file exists for, re-armed for
    /// `isExplicit`.
    ///
    /// `tracks/{catalogId}` is the single source of truth for ALL track
    /// metadata, and every read path swallows a decode failure with `try?`.
    /// A throw therefore surfaces as `merged(withCatalog: nil)` — a silent
    /// no-op leaving title/artist/album empty — so Shelf buckets the entire
    /// library as one "Singles"/"Unknown Artist" tile and Feed/Spotlight
    /// blank out. That shipped exactly once, when `genres` was added: green
    /// build, passing tests, every screen broken on device.
    ///
    /// This decodes a row shaped like every document written BEFORE
    /// `isExplicit` existed — no such key at all — which is what the entire
    /// production catalog looks like today.
    func testCatalogTrackDecodesWithoutIsExplicit() throws {
        let track = try decode(CatalogTrack.self, """
        {
          "title": "Geezus", "artist": "The Game", "album": "The Documentary III",
          "artwork": "art.jpg", "isrc": "ZZA0Z2644843",
          "titleLower": "geezus", "artistLower": "the game",
          "albumLower": "the documentary iii",
          "createdAt": 1, "updatedAt": 2
        }
        """)

        // The fields that went blank last time — these are the real assertion.
        XCTAssertEqual(track.title, "Geezus")
        XCTAssertEqual(track.artist, "The Game")
        XCTAssertEqual(track.album, "The Documentary III")
        XCTAssertFalse(track.isExplicit)
    }

    /// `Post` is persisted via `SnapshotStore` (Home + Feed), where the same
    /// `try?` makes a decode failure invisible — it just turns every launch
    /// back into a cold network load.
    func testPostDecodesWithoutIsExplicit() throws {
        let post = try decode(Post.self, """
        {
          "id": "p1", "uid": "u1", "username": "declan", "catalogId": "c1",
          "title": "Geezus", "artist": "The Game", "album": "The Documentary III",
          "artwork": "art.jpg", "uri": "123", "sourceService": "apple_music",
          "nods": 0, "replayCount": 0, "isSpotlit": false, "createdAt": 1
        }
        """)

        XCTAssertEqual(post.title, "Geezus")
        XCTAssertFalse(post.isExplicit)
    }

    /// And a `LibraryTrackDoc` written before the field existed.
    func testLibraryTrackDocDecodesWithoutIsExplicit() throws {
        let doc = try decode(LibraryTrackDoc.self, """
        {
          "catalogId": "c1", "title": "Geezus", "artist": "The Game",
          "album": "The Documentary III", "artwork": "art.jpg",
          "uri": "123", "sourceService": "apple_music", "savedAt": 1
        }
        """)

        XCTAssertEqual(doc.title, "Geezus")
        XCTAssertFalse(doc.isExplicit)
    }

    /// The overlay is what actually carries the flag to Shelf and Feed —
    /// per-user docs are slim and never store metadata themselves.
    func testMergedWithCatalogCarriesIsExplicit() {
        let catalog = CatalogTrack(
            title: "Geezus", artist: "The Game", album: "The Documentary III",
            artwork: "art.jpg", isExplicit: true, createdAt: 1, updatedAt: 1
        )
        // Slim, exactly as `library/{catalogId}` is written: catalogId +
        // event data, no metadata of its own.
        let slim = LibraryTrackDoc(
            catalogId: "c1", title: "", artist: "", album: "", artwork: "",
            uri: "", sourceService: .appleMusic, savedAt: 1
        )
        XCTAssertFalse(slim.isExplicit)
        XCTAssertTrue(slim.merged(withCatalog: catalog).isExplicit)
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

    // MARK: - Playlist source/lens (the enum-decode trap)

    /// `decodeIfPresent` on an enum THROWS for an unrecognized raw value rather
    /// than returning nil. Without the `try?` guard in Playlist's decoder, a doc
    /// written by a newer client would fail to decode entirely and the playlist
    /// would silently vanish, since the read path swallows failures with `try?`.
    func testPlaylistSurvivesUnknownSourceAndLensRawValues() throws {
        let json = """
        {
            "ownerUid": "u1", "ownerUsername": "declan", "title": "Mystery",
            "visibility": "cosmic", "source": "beamed_down", "lens": "telepathy",
            "trackCount": 4, "createdAt": 1, "updatedAt": 2
        }
        """.data(using: .utf8)!

        let playlist = try JSONDecoder().decode(Playlist.self, from: json)
        XCTAssertEqual(playlist.title, "Mystery")
        XCTAssertEqual(playlist.trackCount, 4)
        // Unknown values fall back rather than taking the whole doc down.
        XCTAssertEqual(playlist.visibility, .friends)
        XCTAssertEqual(playlist.source, .manual)
        XCTAssertNil(playlist.lens)
    }

    func testPlaylistDecodesGeneratedSourceAndLens() throws {
        let json = """
        {
            "ownerUid": "u1", "ownerUsername": "declan", "title": "From Your Circle",
            "source": "generated", "lens": "circle",
            "trackCount": 25, "createdAt": 1, "updatedAt": 2
        }
        """.data(using: .utf8)!

        let playlist = try JSONDecoder().decode(Playlist.self, from: json)
        XCTAssertEqual(playlist.source, .generated)
        XCTAssertEqual(playlist.lens, .circle)
    }

    /// An older doc predating the lens field must still load.
    func testPlaylistWithoutLensKeyDecodes() throws {
        let json = """
        { "ownerUid": "u1", "title": "Old", "source": "party", "createdAt": 1, "updatedAt": 2 }
        """.data(using: .utf8)!
        let playlist = try JSONDecoder().decode(Playlist.self, from: json)
        XCTAssertEqual(playlist.source, .party)
        XCTAssertNil(playlist.lens)
    }

    /// `Song` is persisted via SnapshotStore (Home's topChartSongs). A required
    /// new key would make every existing on-disk snapshot fail to decode, which
    /// the read path swallows with `try?` — silently turning each launch back
    /// into a cold network load with no signal that anything broke.
    func testSongWithoutGenresKeyDecodesToEmpty() throws {
        let json = """
        {
            "id": "s1", "title": "Track", "artist": "Artist", "album": "Album",
            "artwork": "a.jpg", "track_id": "s1", "uri": "s1"
        }
        """.data(using: .utf8)!
        let song = try JSONDecoder().decode(Song.self, from: json)
        XCTAssertEqual(song.title, "Track")
        XCTAssertTrue(song.genres.isEmpty)
    }

    /// 🔴 The exact trap that once blanked every track in the app: a stored
    /// snapshot predates this key, a required decode throws, and
    /// `SnapshotStore.load` swallows it with `try?` — silently turning every
    /// launch into a cold network load with no signal. `true` is the only safe
    /// default: assuming a track we know nothing about is unplayable would
    /// dim and disable real, released music.
    func testSongWithoutIsPlayableKeyDecodesAsPlayable() throws {
        let json = """
        {
            "id": "s1", "title": "Track", "artist": "Artist", "album": "Album",
            "artwork": "a.jpg", "track_id": "s1", "uri": "s1"
        }
        """.data(using: .utf8)!
        let song = try JSONDecoder().decode(Song.self, from: json)
        XCTAssertTrue(song.isPlayable)
        XCTAssertNil(song.releaseDate)
    }

    func testSongDecodesPlayabilityAndReleaseDateWhenPresent() throws {
        let json = """
        {
            "id": "s1", "title": "Track 3", "artist": "Artist", "album": "Album",
            "artwork": "a.jpg", "track_id": "s1", "uri": "s1",
            "isPlayable": false, "releaseDate": "2026-10-03"
        }
        """.data(using: .utf8)!
        let song = try JSONDecoder().decode(Song.self, from: json)
        XCTAssertFalse(song.isPlayable)
        XCTAssertEqual(song.releaseDate, "2026-10-03")
    }

    func testSongDecodesGenresWhenPresent() throws {
        let json = """
        {
            "id": "s1", "title": "Track", "artist": "Artist", "album": "Album",
            "artwork": "a.jpg", "track_id": "s1", "uri": "s1",
            "genres": ["Alternative", "Rock"]
        }
        """.data(using: .utf8)!
        let song = try JSONDecoder().decode(Song.self, from: json)
        XCTAssertEqual(song.genres, ["Alternative", "Rock"])
    }

    // MARK: - CatalogTrack (the regression that blanked every screen)

    /// 🔴 REGRESSION GUARD. `tracks/{catalogId}` is the single source of truth
    /// for all track metadata, and every read path swallows decode failures
    /// with `try?` — so a throw here doesn't surface as an error, it surfaces
    /// as `merged(withCatalog: nil)` leaving title/artist/album empty, which
    /// makes Shelf bucket the entire library as "Singles"/"Unknown Artist" and
    /// blanks Feed and Spotlight.
    ///
    /// This is exactly what shipped when a non-optional `genres` was added to a
    /// type using the SYNTHESIZED decoder: Swift emits `decode` rather than
    /// `decodeIfPresent` for non-optionals and ignores default values, so every
    /// pre-existing document threw. Build was green and all tests passed.
    func testCatalogTrackWithoutGenresKeyStillDecodes() throws {
        // Shaped exactly like a row written before genre ingest existed.
        let json = """
        {
            "title": "Dungarvan Bay", "artist": "The Mary Wallopers",
            "album": "Salt of the Lee - EP", "artwork": "art.jpg",
            "isrc": "GBARL2500268", "titleLower": "dungarvan bay",
            "artistLower": "the mary wallopers", "albumLower": "salt of the lee - ep",
            "createdAt": 1, "updatedAt": 2
        }
        """.data(using: .utf8)!

        let track = try JSONDecoder().decode(CatalogTrack.self, from: json)
        XCTAssertEqual(track.title, "Dungarvan Bay")
        XCTAssertEqual(track.artist, "The Mary Wallopers")
        XCTAssertEqual(track.album, "Salt of the Lee - EP")
        XCTAssertTrue(track.genres.isEmpty)
    }

    func testCatalogTrackDecodesGenresWhenPresent() throws {
        let json = """
        {
            "title": "T", "artist": "A", "album": "Al", "artwork": "",
            "genres": ["Alternative", "Rock"], "createdAt": 1, "updatedAt": 2
        }
        """.data(using: .utf8)!
        XCTAssertEqual(try JSONDecoder().decode(CatalogTrack.self, from: json).genres,
                       ["Alternative", "Rock"])
    }

    /// A minimal row must not throw either — the lowercased fields are derived
    /// on write, so an older row missing them should recompute, not fail.
    func testCatalogTrackDecodesMinimalRowAndDerivesLowercasedFields() throws {
        let json = """
        { "title": "Mixed Case", "artist": "Some Artist" }
        """.data(using: .utf8)!
        let track = try JSONDecoder().decode(CatalogTrack.self, from: json)
        XCTAssertEqual(track.titleLower, "mixed case")
        XCTAssertEqual(track.artistLower, "some artist")
        XCTAssertEqual(track.album, "")
    }
}
