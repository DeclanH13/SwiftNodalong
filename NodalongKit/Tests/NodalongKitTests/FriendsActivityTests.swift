import XCTest
@testable import NodalongKit

final class FriendsActivityTests: XCTestCase {

    private func post(
        uid: String = "friend1",
        username: String = "friend",
        catalogId: String,
        title: String = "Track",
        artist: String,
        album: String,
        artwork: String = "artwork.jpg",
        createdAt: Double,
        nods: Int = 0
    ) -> Post {
        Post(
            id: "\(uid)_\(catalogId)",
            uid: uid,
            username: username,
            catalogId: catalogId,
            title: title,
            artist: artist,
            album: album,
            artwork: artwork,
            uri: catalogId,
            sourceService: .appleMusic,
            nods: nods,
            createdAt: createdAt
        )
    }

    // MARK: - friendsListeningAlbums

    func testGroupsDistinctListenersByAlbumAndRanksByListenerCount() {
        let posts = [
            post(uid: "a", catalogId: "1", artist: "Jamie xx", album: "In Waves", createdAt: 1000),
            post(uid: "b", catalogId: "2", artist: "Jamie xx", album: "In Waves", createdAt: 2000),
            post(uid: "c", catalogId: "3", artist: "Kanye West", album: "Donda", createdAt: 3000),
        ]

        let albums = friendsListeningAlbums(from: posts)

        XCTAssertEqual(albums.count, 2)
        XCTAssertEqual(albums.first?.albumName, "In Waves")
        XCTAssertEqual(albums.first?.listeners.count, 2)
        XCTAssertEqual(albums.last?.listeners.count, 1)
    }

    func testSameUserMultipleTracksCountsAsOneListener() {
        let posts = [
            post(uid: "a", catalogId: "1", artist: "Jamie xx", album: "In Waves", createdAt: 1000),
            post(uid: "a", catalogId: "2", artist: "Jamie xx", album: "In Waves", createdAt: 2000),
        ]

        let albums = friendsListeningAlbums(from: posts)

        XCTAssertEqual(albums.count, 1)
        XCTAssertEqual(albums.first?.listeners.count, 1)
    }

    func testFeaturedArtistTrackGroupsWithPlainAlbumTracks() {
        let posts = [
            post(uid: "a", catalogId: "1", artist: "Jamie xx", album: "In Waves", createdAt: 1000),
            post(uid: "b", catalogId: "2", artist: "Jamie xx & Honey Dijon", album: "In Waves", createdAt: 2000),
        ]

        let albums = friendsListeningAlbums(from: posts)

        XCTAssertEqual(albums.count, 1)
        XCTAssertEqual(albums.first?.listeners.count, 2)
    }

    func testTiedListenerCountBreaksByRecency() {
        let posts = [
            post(uid: "a", catalogId: "1", artist: "Artist X", album: "Older", createdAt: 1000),
            post(uid: "a", catalogId: "2", artist: "Artist Y", album: "Newer", createdAt: 5000),
        ]

        let albums = friendsListeningAlbums(from: posts)

        XCTAssertEqual(albums.first?.albumName, "Newer")
    }

    func testSingleListenerAlbumStillIncluded() {
        let posts = [
            post(uid: "a", catalogId: "1", artist: "Artist", album: "Album", createdAt: 1000),
        ]

        XCTAssertEqual(friendsListeningAlbums(from: posts).count, 1)
    }

    func testPostsWithNoAlbumAreExcluded() {
        let posts = [post(catalogId: "1", artist: "Artist", album: "", createdAt: 1000)]
        XCTAssertTrue(friendsListeningAlbums(from: posts).isEmpty)
    }

    // Reported on device: a various-artists compilation ("HELP(2)") showed
    // as several separate single-track tiles because each track's primary
    // artist genuinely differs — not the feat.-credit variance
    // `primaryArtist` already handles. Grouping by album name alone merges
    // them into one group, labeled "Various Artists".
    func testVariousArtistsCompilationMergesIntoOneAlbum() {
        let posts = [
            post(uid: "a", catalogId: "1", artist: "Artist A", album: "HELP(2)", createdAt: 1000),
            post(uid: "b", catalogId: "2", artist: "Artist B", album: "HELP(2)", createdAt: 2000),
            post(uid: "c", catalogId: "3", artist: "Artist C", album: "HELP(2)", createdAt: 3000),
        ]

        let albums = friendsListeningAlbums(from: posts)

        XCTAssertEqual(albums.count, 1)
        XCTAssertEqual(albums.first?.listeners.count, 3)
        XCTAssertEqual(albums.first?.artistName, variousArtistsLabel)
    }

    // MARK: - mostNoddedPosts

    func testSumsNodsAcrossDuplicateTracksAndRanksDescending() {
        let posts = [
            post(uid: "a", catalogId: "song1", artist: "Artist", album: "Album", createdAt: 1000, nods: 3),
            post(uid: "b", catalogId: "song1", artist: "Artist", album: "Album", createdAt: 2000, nods: 4),
            post(uid: "c", catalogId: "song2", artist: "Artist", album: "Album", createdAt: 3000, nods: 1),
        ]

        let ranked = mostNoddedPosts(from: posts, since: 0)

        XCTAssertEqual(ranked.count, 2)
        XCTAssertEqual(ranked.first?.catalogId, "song1")
        XCTAssertEqual(ranked.first?.nods, 7)
        XCTAssertEqual(ranked.last?.catalogId, "song2")
        XCTAssertEqual(ranked.last?.nods, 1)
    }

    func testExcludesPostsBeforeCutoff() {
        let posts = [
            post(catalogId: "old", artist: "Artist", album: "Album", createdAt: 1000, nods: 5),
            post(catalogId: "new", artist: "Artist", album: "Album", createdAt: 9000, nods: 2),
        ]

        let ranked = mostNoddedPosts(from: posts, since: 5000)

        XCTAssertEqual(ranked.count, 1)
        XCTAssertEqual(ranked.first?.catalogId, "new")
    }

    func testExcludesZeroNodTracks() {
        let posts = [post(catalogId: "1", artist: "Artist", album: "Album", createdAt: 1000, nods: 0)]
        XCTAssertTrue(mostNoddedPosts(from: posts, since: 0).isEmpty)
    }

    func testRepresentativePostIsMostRecentInGroup() {
        let posts = [
            post(uid: "a", catalogId: "song1", title: "Old Title", artist: "Artist", album: "Album", artwork: "old.jpg", createdAt: 1000, nods: 1),
            post(uid: "b", catalogId: "song1", title: "New Title", artist: "Artist", album: "Album", artwork: "new.jpg", createdAt: 5000, nods: 1),
        ]

        let ranked = mostNoddedPosts(from: posts, since: 0)

        XCTAssertEqual(ranked.first?.title, "New Title")
        XCTAssertEqual(ranked.first?.artwork, "new.jpg")
    }

    func testLimitCapsResultCount() {
        let posts = (0..<5).map { i in
            post(catalogId: "song\(i)", artist: "Artist", album: "Album", createdAt: Double(i), nods: i + 1)
        }

        let ranked = mostNoddedPosts(from: posts, since: 0, limit: 2)

        XCTAssertEqual(ranked.count, 2)
    }
}
