import XCTest
@testable import NodalongKit

final class GroupByAlbumTests: XCTestCase {

    private func track(
        catalogId: String,
        title: String,
        artist: String,
        album: String,
        trackNumber: Int? = nil,
        isExplicit: Bool = false
    ) -> LibraryTrackDoc {
        LibraryTrackDoc(
            catalogId: catalogId,
            title: title,
            artist: artist,
            album: album,
            artwork: "",
            uri: catalogId,
            sourceService: .appleMusic,
            trackNumber: trackNumber,
            isExplicit: isExplicit,
            savedAt: 0
        )
    }

    // MARK: - Album-level explicit

    // An album is marked explicit if ANY of its tracks is — the convention
    // music apps use.
    func testAlbumIsExplicitWhenAnyTrackIs() {
        let groups = groupByAlbum([
            track(catalogId: "1", title: "A", artist: "X", album: "LP", trackNumber: 1),
            track(catalogId: "2", title: "B", artist: "X", album: "LP", trackNumber: 2, isExplicit: true),
        ])
        XCTAssertEqual(groups.count, 1)
        XCTAssertTrue(groups[0].isExplicit)
    }

    func testAlbumIsNotExplicitWhenNoTrackIs() {
        let groups = groupByAlbum([
            track(catalogId: "1", title: "A", artist: "X", album: "LP", trackNumber: 1),
            track(catalogId: "2", title: "B", artist: "X", album: "LP", trackNumber: 2),
        ])
        XCTAssertEqual(groups.count, 1)
        XCTAssertFalse(groups[0].isExplicit)
    }

    // `false` for an unmarked album is load-bearing: the flag is captured at
    // ingest and backfills incrementally, so "not captured yet" is common and
    // must never read as explicit.
    func testAlbumWithNoExplicitDataIsNotMarked() {
        let groups = groupByAlbum([
            track(catalogId: "1", title: "A", artist: "X", album: "LP")
        ])
        XCTAssertFalse(groups[0].isExplicit)
    }

    // A featured-artist track (e.g. "Jamie xx & Honey Dijon") must group with
    // the rest of its album, not split off into its own "album" — the bug
    // reported against Jamie xx's "In Waves".
    func testFeaturedArtistTrackGroupsWithPlainAlbumTracks() {
        let tracks = [
            track(catalogId: "1", title: "Waited All Night", artist: "Jamie xx", album: "In Waves", trackNumber: 1),
            track(catalogId: "2", title: "Baddy on the Floor", artist: "Jamie xx & Honey Dijon", album: "In Waves", trackNumber: 2),
            track(catalogId: "3", title: "Falling Together", artist: "Jamie xx & The Avalanches", album: "In Waves", trackNumber: 3),
        ]

        let groups = groupByAlbum(tracks)

        XCTAssertEqual(groups.count, 1, "expected all three tracks in one album group, got \(groups.count)")
        XCTAssertEqual(groups.first?.trackCount, 3)
        XCTAssertEqual(groups.first?.albumName, "In Waves")
    }

    func testDifferentAlbumsByDifferentArtistsStaySeparate() {
        let tracks = [
            track(catalogId: "1", title: "A", artist: "Jamie xx", album: "In Waves"),
            track(catalogId: "2", title: "B", artist: "Some Other Artist", album: "Unrelated Album"),
        ]

        let groups = groupByAlbum(tracks)

        XCTAssertEqual(groups.count, 2)
    }

    // A "feat." credit (the pre-existing behavior) must still split correctly
    // — the fix is a superset, not a replacement, of the old splitting.
    func testFeatDotCreditStillGroupsWithPlainAlbumTracks() {
        let tracks = [
            track(catalogId: "1", title: "A", artist: "Artist X", album: "Album Y"),
            track(catalogId: "2", title: "B", artist: "Artist X feat. Guest", album: "Album Y"),
        ]

        let groups = groupByAlbum(tracks)

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.trackCount, 2)
    }

    // Reported on device: saving a 4-track EP left 3 tracks under "Salt of
    // the Lee - EP" and split the 4th into its own single-track group — a
    // track ingested through a different path than the rest of the album
    // (e.g. an earlier individual play/like/sync) carried a differently
    // edition-suffixed album string for the same real release.
    func testEditionSuffixVariantsGroupIntoOneAlbum() {
        let tracks = [
            track(catalogId: "1", title: "Track One", artist: "Cliffords", album: "Salt of the Lee - EP", trackNumber: 1),
            track(catalogId: "2", title: "Track Two", artist: "Cliffords", album: "Salt of the Lee - EP", trackNumber: 2),
            track(catalogId: "3", title: "Track Three", artist: "Cliffords", album: "Salt of the Lee - EP", trackNumber: 3),
            track(catalogId: "4", title: "Track Four", artist: "Cliffords", album: "Salt of the Lee", trackNumber: 4),
        ]

        let groups = groupByAlbum(tracks)

        XCTAssertEqual(groups.count, 1, "expected all four tracks in one album group, got \(groups.count)")
        XCTAssertEqual(groups.first?.trackCount, 4)
    }

    // Guards against `stripSearchNoise` being too aggressive — two genuinely
    // different albums by the same artist must stay separate.
    func testGenuinelyDifferentAlbumsStaySeparateAfterNoiseStripping() {
        let tracks = [
            track(catalogId: "1", title: "A", artist: "Artist", album: "Volume One"),
            track(catalogId: "2", title: "B", artist: "Artist", album: "Volume Two"),
        ]

        XCTAssertEqual(groupByAlbum(tracks).count, 2)
    }

    // Reported on device: a various-artists compilation ("HELP(2)") showed
    // as several separate single-track tiles because each track's primary
    // artist genuinely differs — not the feat.-credit variance
    // `primaryArtist` already handles. Grouping by album name alone merges
    // them into one group, labeled "Various Artists".
    func testVariousArtistsCompilationMergesIntoOneAlbum() {
        let tracks = [
            track(catalogId: "1", title: "Track One", artist: "Artist A", album: "HELP(2)", trackNumber: 1),
            track(catalogId: "2", title: "Track Two", artist: "Artist B", album: "HELP(2)", trackNumber: 2),
            track(catalogId: "3", title: "Track Three", artist: "Artist C", album: "HELP(2)", trackNumber: 3),
        ]

        let groups = groupByAlbum(tracks)

        XCTAssertEqual(groups.count, 1, "expected all three tracks in one album group, got \(groups.count)")
        XCTAssertEqual(groups.first?.trackCount, 3)
        XCTAssertEqual(groups.first?.artistName, variousArtistsLabel)
    }

    // Dropping artist from the grouping key must NOT apply to tracks with
    // no album at all — otherwise every artist's standalone singles would
    // collapse into one giant cross-artist "Singles" bucket.
    func testDifferentArtistsStandaloneSinglesStaySeparate() {
        let tracks = [
            track(catalogId: "1", title: "Solo Track A", artist: "Artist A", album: ""),
            track(catalogId: "2", title: "Solo Track B", artist: "Artist B", album: ""),
        ]

        let groups = groupByAlbum(tracks)

        XCTAssertEqual(groups.count, 2)
        XCTAssertTrue(groups.allSatisfy { $0.albumName == "Singles" })
    }
}
