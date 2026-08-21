import XCTest
@testable import NodalongKit

/// Confirms `FriendSpotlight` and `RecommendationShelf` round-trip through
/// JSON — both gained `Codable` so `HomeViewModel` can persist them in a
/// stale-while-revalidate launch snapshot (see `SnapshotStore`).
final class SnapshotCodableTests: XCTestCase {

    func testFriendSpotlightRoundTrips() throws {
        let user = UserProfile(
            uid: "u1", email: "a@b.com", username: "alice", bio: "",
            lastActive: 1, createdAt: 1, updatedAt: 1
        )
        let track = SpotlightTrack(
            trackId: "t1", title: "Song", artist: "Artist", album: "Album",
            artwork: "https://example.com/art.jpg", uri: "apple:t1", spotlitAt: 123
        )
        let original = FriendSpotlight(user: user, track: track)

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(FriendSpotlight.self, from: data)

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.id, original.id)
    }

    func testRecommendationShelfRoundTrips() throws {
        let album = AlbumResult(
            id: "a1", name: "Album", artistName: "Artist",
            artwork: "https://example.com/art.jpg", releaseDate: "2026",
            totalTracks: 10, albumType: "album", sourceService: .appleMusic
        )
        let original = RecommendationShelf(id: "shelf1", title: "New Music Mix", albums: [album])

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RecommendationShelf.self, from: data)

        XCTAssertEqual(decoded, original)
    }
}
