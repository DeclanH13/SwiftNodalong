import XCTest
@testable import NodalongKit

final class GroupPostsByAlbumTests: XCTestCase {

    private func post(
        catalogId: String,
        title: String,
        artist: String,
        album: String,
        artwork: String = "artwork.jpg",
        createdAt: Double,
        replayCount: Int = 0
    ) -> Post {
        Post(
            id: "u_\(catalogId)",
            uid: "u",
            username: "user",
            catalogId: catalogId,
            title: title,
            artist: artist,
            album: album,
            artwork: artwork,
            uri: catalogId,
            sourceService: .appleMusic,
            replayCount: replayCount,
            createdAt: createdAt
        )
    }

    // A featured-artist track (e.g. "Jamie xx & Honey Dijon") must still
    // dedupe into the same album group as the album's plain tracks.
    func testFeaturedArtistTrackGroupsWithPlainAlbumTracks() {
        let posts = [
            post(catalogId: "1", title: "Waited All Night", artist: "Jamie xx", album: "In Waves", createdAt: 1000),
            post(catalogId: "2", title: "Baddy on the Floor", artist: "Jamie xx & Honey Dijon", album: "In Waves", createdAt: 2000),
        ]

        let albums = recentAlbums(from: posts)

        XCTAssertEqual(albums.count, 1)
        XCTAssertEqual(albums.first?.albumName, "In Waves")
    }

    func testRepresentativeIsTheMostRecentlyPlayedTrack() {
        let posts = [
            post(catalogId: "1", title: "A", artist: "Artist", album: "Album", artwork: "old.jpg", createdAt: 1000),
            post(catalogId: "2", title: "B", artist: "Artist", album: "Album", artwork: "new.jpg", createdAt: 5000),
        ]

        let albums = recentAlbums(from: posts)

        XCTAssertEqual(albums.count, 1)
        XCTAssertEqual(albums.first?.catalogId, "2")
        XCTAssertEqual(albums.first?.artwork, "new.jpg")
        XCTAssertEqual(albums.first?.mostRecentPlayedAt, 5000)
    }

    func testDifferentAlbumsStaySeparateAndSortByRecency() {
        let posts = [
            post(catalogId: "1", title: "A", artist: "Artist X", album: "Older Album", createdAt: 1000),
            post(catalogId: "2", title: "B", artist: "Artist Y", album: "Newer Album", createdAt: 5000),
        ]

        let albums = recentAlbums(from: posts)

        XCTAssertEqual(albums.count, 2)
        XCTAssertEqual(albums.first?.albumName, "Newer Album")
        XCTAssertEqual(albums.last?.albumName, "Older Album")
    }

    func testTotalReplayCountSumsAcrossTracksInTheGroup() {
        let posts = [
            post(catalogId: "1", title: "A", artist: "Artist", album: "Album", createdAt: 1000, replayCount: 2),
            post(catalogId: "2", title: "B", artist: "Artist", album: "Album", createdAt: 2000, replayCount: 3),
        ]

        let albums = recentAlbums(from: posts)

        XCTAssertEqual(albums.count, 1)
        XCTAssertEqual(albums.first?.totalReplayCount, 5)
    }

    func testPostsWithNoAlbumAreExcluded() {
        let posts = [
            post(catalogId: "1", title: "A", artist: "Artist", album: "", createdAt: 1000),
        ]

        XCTAssertTrue(recentAlbums(from: posts).isEmpty)
    }

    // Confirmed on device: the same release can carry an inconsistent
    // edition suffix depending on which context resolved it — "SKAGABOO"
    // vs "SKAGABOO - EP" — which used to split one album into two Jump
    // Back In tiles despite sharing the same artist.
    func testEditionSuffixVariantsGroupIntoOneAlbum() {
        let posts = [
            post(catalogId: "1", title: "Track One", artist: "Lil Skag & Sugabooo", album: "SKAGABOO", createdAt: 1000),
            post(catalogId: "2", title: "Track Two", artist: "Lil Skag & Sugabooo", album: "SKAGABOO - EP", createdAt: 2000),
        ]

        let albums = recentAlbums(from: posts)

        XCTAssertEqual(albums.count, 1)
        // Display name is the untouched, real title of whichever play is
        // most recent — normalization only affects the grouping key, not
        // what's shown on the tile.
        XCTAssertEqual(albums.first?.albumName, "SKAGABOO - EP")
    }

    // Guards against `stripSearchNoise` being too aggressive — two
    // genuinely different albums by the same artist must stay separate,
    // not collapse just because normalization is now applied.
    func testGenuinelyDifferentAlbumsStaySeparateAfterNoiseStripping() {
        let posts = [
            post(catalogId: "1", title: "A", artist: "Artist", album: "Volume One", createdAt: 1000),
            post(catalogId: "2", title: "B", artist: "Artist", album: "Volume Two", createdAt: 2000),
        ]

        XCTAssertEqual(recentAlbums(from: posts).count, 2)
    }

    // Reported on device: a various-artists compilation ("HELP(2)") showed
    // as several separate single-track tiles in Jump Back In because each
    // track's primary artist genuinely differs — not the feat.-credit
    // variance `primaryArtist` already handles. Grouping by album name
    // alone merges them into one group, labeled "Various Artists".
    func testVariousArtistsCompilationMergesIntoOneAlbum() {
        let posts = [
            post(catalogId: "1", title: "Track One", artist: "Artist A", album: "HELP(2)", createdAt: 1000),
            post(catalogId: "2", title: "Track Two", artist: "Artist B", album: "HELP(2)", createdAt: 2000),
            post(catalogId: "3", title: "Track Three", artist: "Artist C", album: "HELP(2)", createdAt: 3000),
        ]

        let albums = recentAlbums(from: posts)

        XCTAssertEqual(albums.count, 1)
        XCTAssertEqual(albums.first?.artistName, variousArtistsLabel)
    }
}
