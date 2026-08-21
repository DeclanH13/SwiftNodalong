import XCTest
@testable import NodalongKit

final class SearchScoringTests: XCTestCase {

    // --- tokenize ---

    func testTokenizeBasic() {
        XCTAssertEqual(tokenize("Kanye LIGHTS"), ["kanye", "lights"])
    }

    func testTokenizeDeduplicates() {
        XCTAssertEqual(tokenize("lights LIGHTS"), ["lights"])
    }

    func testTokenizeEmptyString() {
        XCTAssertEqual(tokenize(""), [])
    }

    func testTokenizeExtraWhitespace() {
        XCTAssertEqual(tokenize("  foo   bar  "), ["foo", "bar"])
    }

    // --- matchesAllTokens ---

    func testMatchesAllTokensCrossField() {
        // "kanye" in artist, "lights" in title → all tokens satisfied
        XCTAssertTrue(matchesAllTokens(["kanye", "lights"], fields: ["flashing lights", "kanye west", ""]))
    }

    func testMatchesAllTokensFailsIfTokenMissing() {
        XCTAssertFalse(matchesAllTokens(["kanye", "power"], fields: ["flashing lights", "kanye west", ""]))
    }

    func testMatchesAllTokensEmptyTokens() {
        XCTAssertTrue(matchesAllTokens([], fields: ["anything"]))
    }

    // --- scoreTrack ---

    func testScoreTitleMatchOutranksArtistMatch() {
        let titleScore = scoreTrack(tokens: ["lights"], title: "Flashing Lights", artist: "Kanye West", album: "MBDTF")
        let artistScore = scoreTrack(tokens: ["kanye"], title: "Flashing Lights", artist: "Kanye West", album: "MBDTF")
        // "lights" in title → 4 + 2 (word prefix)
        // "kanye" in artist → 2 + 2 (word prefix)
        XCTAssertGreaterThan(titleScore, artistScore)
    }

    func testScoreWordPrefixBonus() {
        // "lights" starts a word in title → gets the +2 prefix bonus
        let withBonus = scoreTrack(tokens: ["lights"], title: "Lights Out", artist: "", album: "")
        // "lights" is mid-word only → no bonus
        let withoutBonus = scoreTrack(tokens: ["lights"], title: "Flighting", artist: "", album: "")
        XCTAssertGreaterThan(withBonus, withoutBonus)
    }

    func testScoreAlbumOnly() {
        let s = scoreTrack(tokens: ["fantasy"], title: "Power", artist: "Kanye West", album: "My Beautiful Dark Twisted Fantasy")
        XCTAssertEqual(s, 1)
    }

    func testScoreZeroNoMatch() {
        let s = scoreTrack(tokens: ["zzz"], title: "Power", artist: "Kanye West", album: "MBDTF")
        XCTAssertEqual(s, 0)
    }

    // --- rankByRelevance ---

    func testRankByRelevanceOrder() {
        let items = ["c", "b", "a"]
        let scored: [String: Int] = ["a": 10, "b": 5, "c": 1]
        let ranked = rankByRelevance(items) { scored[$0] ?? 0 }
        XCTAssertEqual(ranked, ["a", "b", "c"])
    }

    func testRankByRelevanceStableOnTie() {
        // Items with equal score keep original relative order.
        let items = ["first", "second", "third"]
        let ranked = rankByRelevance(items) { _ in 1 }
        XCTAssertEqual(ranked, ["first", "second", "third"])
    }
}
