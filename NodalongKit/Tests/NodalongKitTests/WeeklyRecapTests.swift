import XCTest
@testable import NodalongKit

final class WeeklyRecapTests: XCTestCase {
    private let start = 1_000_000.0
    private let end = 1_000_000.0 + 7 * 86_400_000

    private func post(_ uid: String = "me", artist: String, at: Double, nods: Int = 0, id: String = UUID().uuidString) -> Post {
        Post(id: id, uid: uid, username: uid, catalogId: id, title: "t", artist: artist, album: "a",
             artwork: "", uri: id, sourceService: .appleMusic, nods: nods, createdAt: at)
    }

    func testWindowBoundaries() {
        let posts = [post(artist: "A", at: start), post(artist: "A", at: end - 1), post(artist: "A", at: end),
                     post(artist: "A", at: start - 1)]
        let r = buildWeeklyRecap(myPosts: posts, myLibrary: [], mySpotlights: [], friendPosts: [],
                                 weekStartMs: start, weekEndMs: end)
        XCTAssertEqual(r.playCount, 2)
    }

    func testTopArtistsNormalizeFeaturedCredits() {
        let posts = [post(artist: "Dahi", at: start + 1), post(artist: "Dahi & Childish Gambino", at: start + 2),
                     post(artist: "Other", at: start + 3)]
        let r = buildWeeklyRecap(myPosts: posts, myLibrary: [], mySpotlights: [], friendPosts: [],
                                 weekStartMs: start, weekEndMs: end)
        XCTAssertEqual(r.topArtists.first?.plays, 2)
        XCTAssertEqual(r.topArtists.count, 2)
    }

    func testNodsOnlyCountInsideWindow() {
        let posts = [post(artist: "A", at: start + 1, nods: 3), post(artist: "A", at: start - 5, nods: 9)]
        let r = buildWeeklyRecap(myPosts: posts, myLibrary: [], mySpotlights: [], friendPosts: [],
                                 weekStartMs: start, weekEndMs: end)
        XCTAssertEqual(r.nodsReceived, 3)
    }

    func testMostInSyncPicksFriendWithMostSharedArtists() {
        let mine = [post(artist: "A", at: start + 1), post(artist: "B", at: start + 2)]
        let friends = [post("x", artist: "A", at: start + 3), post("y", artist: "A", at: start + 3),
                       post("y", artist: "B", at: start + 4)]
        let r = buildWeeklyRecap(myPosts: mine, myLibrary: [], mySpotlights: [], friendPosts: friends,
                                 weekStartMs: start, weekEndMs: end)
        XCTAssertEqual(r.mostInSync?.username, "y")
        XCTAssertEqual(r.mostInSync?.sharedArtists, 2)
    }

    func testFriendTrackOfTheWeekIsMostNodded() {
        let friends = [post("x", artist: "A", at: start + 1, nods: 2, id: "p1"),
                       post("y", artist: "B", at: start + 2, nods: 5, id: "p2")]
        let r = buildWeeklyRecap(myPosts: [], myLibrary: [], mySpotlights: [], friendPosts: friends,
                                 weekStartMs: start, weekEndMs: end)
        XCTAssertEqual(r.friendTrackOfTheWeek?.id, "p2")
    }

    func testEmptyWeek() {
        let r = buildWeeklyRecap(myPosts: [], myLibrary: [], mySpotlights: [], friendPosts: [],
                                 weekStartMs: start, weekEndMs: end)
        XCTAssertTrue(r.isEmpty)
    }
}
