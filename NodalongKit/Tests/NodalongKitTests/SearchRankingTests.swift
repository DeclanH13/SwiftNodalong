import XCTest
@testable import NodalongKit

final class SearchRankingTests: XCTestCase {
    private func track(_ title: String, _ artist: String, album: String = "", genres: [String] = [], key: String? = nil) -> SearchHit {
        .track(SearchItem(key: key ?? "\(title)-\(artist)", title: title, artist: artist, album: album,
                          artwork: "", uri: "u", sourceService: .appleMusic, genres: genres))
    }
    private func artist(_ name: String) -> SearchHit {
        .artist(ArtistResult(id: name, name: name, imageUrl: "", genres: "", followers: 0, sourceService: .appleMusic))
    }
    private func titles(_ hits: [SearchHit]) -> [String] { hits.map { "\($0.title)|\($0.artistName)" } }

    func testExactTitleBeatsUnrelatedArtist() {
        let hits = [artist("Shaboozey"), track("Good News", "Mac Miller")]
        let ranked = rankSearchHits(hits, query: "good news")
        XCTAssertEqual(ranked.first?.title, "Good News")
        XCTAssertEqual(ranked.last?.title, "Shaboozey")
    }

    func testTasteBreaksTiesWithinATier() {
        let hits = [track("Good News", "Other Artist"), track("Good News", "Mac Miller")]
        let taste = TasteWeights(artists: ["mac miller": 1.0])
        XCTAssertEqual(rankSearchHits(hits, query: "good news", taste: taste).first?.artistName, "Mac Miller")
        XCTAssertEqual(rankSearchHits(hits, query: "good news").first?.artistName, "Other Artist") // no taste: service order
    }

    func testTasteNeverLiftsAWeakerTier() {
        let hits = [track("Something Else", "Mac Miller"), track("Good News", "Nobody")]
        let taste = TasteWeights(artists: ["mac miller": 1.0])
        XCTAssertEqual(rankSearchHits(hits, query: "good news", taste: taste).first?.title, "Good News")
    }

    func testArtistWordsInQueryHelpTheRightSong() {
        let hits = [track("Good News", "Other Artist"), track("Good News", "Mac Miller")]
        XCTAssertEqual(rankSearchHits(hits, query: "good news mac miller").first?.artistName, "Mac Miller")
    }

    func testBlockedArtistGetsNoBoost() {
        let hits = [track("Good News", "Other Artist"), track("Good News", "Mac Miller")]
        let taste = TasteWeights(artists: ["mac miller": 1.0], blocked: ["mac miller"])
        XCTAssertEqual(rankSearchHits(hits, query: "good news", taste: taste).first?.artistName, "Other Artist")
    }

    func testGenreBoostUsesTrackGenres() {
        let hits = [track("Hello", "A", genres: ["Pop"]), track("Hello", "B", genres: ["Hip-Hop"])]
        let taste = TasteWeights(genres: ["hip-hop": 1.0])
        XCTAssertEqual(rankSearchHits(hits, query: "hello", taste: taste).first?.artistName, "B")
    }

    func testDuplicateEditionsCollapse() {
        let hits = [track("Good News", "Mac Miller", key: "1"), track("Good News (Remastered)", "Mac Miller", key: "2")]
        XCTAssertEqual(rankSearchHits(hits, query: "good news").count, 1)
    }

    func testEmptyQueryLeavesOrderAlone() {
        let hits = [track("B", "x"), track("A", "y")]
        XCTAssertEqual(titles(rankSearchHits(hits, query: "  ")), titles(hits))
    }

    // MARK: albums on equal footing
    private func album(_ name: String, _ artistName: String, genres: [String] = []) -> SearchHit {
        .album(AlbumResult(id: name + artistName, name: name, artistName: artistName, artwork: "", releaseDate: "",
                           totalTracks: 5, sourceService: .appleMusic, genres: genres))
    }

    func testAlbumsOfAListenedToGenreBeatAStrangersSong() {
        let taste = TasteWeights(genres: ["rock": 1.0])
        let hits = [track("Wish", "Stranger", genres: ["Polka"], key: "s"), album("Wish", "Floyd", genres: ["Rock"])]
        XCTAssertTrue(rankSearchHits(hits, query: "wish", taste: taste).first!.id.hasPrefix("album"))
    }

    func testDiversityPullsOtherKindsIntoTheFirstScreenWithinATier() {
        var hits: [SearchHit] = (0..<10).map { track("Pink \($0)", "Pink Floyd", key: "t\($0)") }
        hits.append(album("Pink Floyd EP", "Pink Floyd"))
        hits.append(artist("Pink Floyd"))
        let ranked = rankSearchHits(hits, query: "pink floyd")
        XCTAssertTrue(ranked.prefix(8).contains { if case .album = $0 { return true }; return false } ||
                      ranked.prefix(8).contains { if case .artist = $0 { return true }; return false })
    }

    func testDiversityNeverCrossesAMatchTier() {
        var hits: [SearchHit] = (0..<8).map { track("Exact", "A\($0)", key: "t\($0)") }   // tier 5
        hits.append(album("Something Else", "Nobody"))                                   // tier 0
        let ranked = rankSearchHits(hits, query: "exact")
        XCTAssertTrue(ranked.prefix(8).allSatisfy { if case .track = $0 { return true }; return false })
    }

    // MARK: local artist prefix matches
    func testLocalMatchOnPrefixAndWordPrefix() {
        XCTAssertEqual(localArtistMatches(query: "pink floy", candidates: ["Pink Floyd", "Kendrick Lamar"]), ["Pink Floyd"])
        XCTAssertEqual(localArtistMatches(query: "pink fl", candidates: ["Pink Floyd"]), ["Pink Floyd"])
        XCTAssertEqual(localArtistMatches(query: "kend", candidates: ["Kendrick Lamar"]), ["Kendrick Lamar"])
        XCTAssertEqual(localArtistMatches(query: "floyd", candidates: ["Pink Floyd"]), [])   // first word must anchor
    }

    func testLocalMatchNeedsThreeCharactersAndSkipsBlocked() {
        XCTAssertTrue(localArtistMatches(query: "pi", candidates: ["Pink Floyd"]).isEmpty)
        XCTAssertTrue(localArtistMatches(query: "pink", candidates: ["Pink Floyd"], weights: TasteWeights(blocked: ["pink floyd"])).isEmpty)
    }

    func testLocalMatchesPreferHeavilyPlayedArtists() {
        let w = TasteWeights(artists: ["pink floyd": 0.9, "pink": 0.1])
        XCTAssertEqual(localArtistMatches(query: "pink", candidates: ["Pink", "Pink Floyd"], weights: w, limit: 1), ["Pink Floyd"])
    }

    func testMergingArtistsDedupes() {
        let a = ArtistResult(id: "1", name: "Pink Floyd", imageUrl: "", genres: "", followers: 0, sourceService: .appleMusic)
        let b = ArtistResult(id: "2", name: "pink floyd", imageUrl: "", genres: "", followers: 0, sourceService: .appleMusic)
        let c = ArtistResult(id: "3", name: "Other", imageUrl: "", genres: "", followers: 0, sourceService: .appleMusic)
        XCTAssertEqual(mergingArtists([b, c], into: [a]).map(\.id), ["3", "1"])
    }
}
