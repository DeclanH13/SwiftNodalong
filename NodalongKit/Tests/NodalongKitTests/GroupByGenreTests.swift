import XCTest
@testable import NodalongKit

final class GroupByGenreTests: XCTestCase {

    private func doc(
        _ catalogId: String,
        artist: String = "Some Artist",
        artwork: String = "art.jpg",
        savedAt: Double = 0,
        genres: [String]
    ) -> LibraryTrackDoc {
        LibraryTrackDoc(
            catalogId: catalogId,
            title: "Track \(catalogId)",
            artist: artist,
            album: "Album",
            artwork: artwork,
            uri: catalogId,
            sourceService: .appleMusic,
            genres: genres,
            savedAt: savedAt
        )
    }

    func testBucketsByGenre() {
        let entries = groupByGenre([
            doc("t1", genres: ["Rock"]),
            doc("t2", genres: ["Rock"]),
            doc("t3", genres: ["Jazz"]),
        ])
        XCTAssertEqual(entries.map(\.name), ["Rock", "Jazz"])
        XCTAssertEqual(entries.first?.trackCount, 2)
    }

    /// A track with several genres counts under each — so totals deliberately
    /// exceed the library size. This is a bucketing, not a partition.
    func testMultiGenreTrackCountsInEveryBucket() {
        let entries = groupByGenre([doc("t1", genres: ["Rock", "Alternative"])])
        XCTAssertEqual(entries.count, 2)
        XCTAssertTrue(entries.allSatisfy { $0.trackCount == 1 })
    }

    /// Empty genre means "not captured yet" (a catalog row predating genre
    /// ingest), not "genre-less" — surfacing it as a bucket would present
    /// missing data as a fact about the music.
    func testTracksWithoutGenreAreSkippedNotBucketedAsUnknown() {
        let entries = groupByGenre([
            doc("t1", genres: []),
            doc("t2", genres: ["  "]),
            doc("t3", genres: ["Rock"]),
        ])
        XCTAssertEqual(entries.map(\.name), ["Rock"])
    }

    func testCaseInsensitiveDedupKeepsFirstCasing() {
        let entries = groupByGenre([
            doc("t1", genres: ["Hip-Hop"]),
            doc("t2", genres: ["hip-hop"]),
        ])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.trackCount, 2)
    }

    func testArtistCountUsesPrimaryArtistNormalization() {
        let entries = groupByGenre([
            doc("t1", artist: "Dahi", genres: ["Rap"]),
            doc("t2", artist: "Dahi & Childish Gambino", genres: ["Rap"]),
            doc("t3", artist: "Geese", genres: ["Rap"]),
        ])
        XCTAssertEqual(entries.first?.artistCount, 2, "featured credits collapse onto the primary artist")
    }

    func testArtworkComesFromMostRecentlySavedTrack() {
        let entries = groupByGenre([
            doc("old", artwork: "old.jpg", savedAt: 1, genres: ["Rock"]),
            doc("new", artwork: "new.jpg", savedAt: 99, genres: ["Rock"]),
        ])
        XCTAssertEqual(entries.first?.artwork, "new.jpg")
    }

    /// Stable ordering — the grid must not reshuffle between renders.
    func testTiedBucketsOrderDeterministically() {
        let tracks = [doc("t1", genres: ["Zydeco"]), doc("t2", genres: ["Ambient"])]
        let a = groupByGenre(tracks)
        let b = groupByGenre(tracks.reversed())
        XCTAssertEqual(a.map(\.name), ["Ambient", "Zydeco"])
        XCTAssertEqual(a.map(\.name), b.map(\.name))
    }

    func testEmptyLibraryYieldsNoBuckets() {
        XCTAssertTrue(groupByGenre([]).isEmpty)
    }

    // MARK: tracksInGenre

    func testTracksInGenreFiltersCaseInsensitivelyNewestFirst() {
        let result = tracksInGenre("rock", from: [
            doc("old", savedAt: 1, genres: ["Rock"]),
            doc("jazz", savedAt: 50, genres: ["Jazz"]),
            doc("new", savedAt: 99, genres: ["ROCK"]),
        ])
        XCTAssertEqual(result.map(\.catalogId), ["new", "old"])
    }
}
