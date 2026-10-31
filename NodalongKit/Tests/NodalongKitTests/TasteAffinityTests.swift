import XCTest
@testable import NodalongKit

final class TasteAffinityTests: XCTestCase {

    private func profile(tracks: [String] = [], artists: [String] = []) -> TasteProfile {
        var p = TasteProfile()
        for t in tracks { p.add(catalogId: t, artist: "artist_for_\(t)") }
        for a in artists { p.add(catalogId: nil, artist: a) }
        return p
    }

    // MARK: TasteProfile

    func testAddNormalizesFeaturedCreditsToPrimaryArtist() {
        var p = TasteProfile()
        p.add(catalogId: "t1", artist: "Dahi & Childish Gambino")
        p.add(catalogId: "t2", artist: "Dahi")
        p.add(catalogId: "t3", artist: "Dahi feat. Kendrick Lamar")
        // All three collapse onto one artist — same rule groupByAlbum uses.
        XCTAssertEqual(p.artists, ["dahi"])
        XCTAssertEqual(p.trackIds, ["t1", "t2", "t3"])
    }

    func testAddIgnoresEmptyCatalogIdButKeepsArtist() {
        var p = TasteProfile()
        p.add(catalogId: "", artist: "Wolf Alice")
        p.add(catalogId: nil, artist: "Geese")
        XCTAssertTrue(p.trackIds.isEmpty)
        XCTAssertEqual(p.artists, ["wolf alice", "geese"])
    }

    func testMergingUnionsBothDimensions() {
        let a = profile(tracks: ["t1"], artists: ["Paramore"])
        let b = profile(tracks: ["t2"], artists: ["Geese"])
        let merged = a.merging(b)
        XCTAssertTrue(merged.trackIds.isSuperset(of: ["t1", "t2"]))
        XCTAssertTrue(merged.artists.isSuperset(of: ["paramore", "geese"]))
    }

    // MARK: affinity

    func testIdenticalTasteScoresOne() {
        let p = profile(tracks: ["t1", "t2"], artists: ["Paramore"])
        XCTAssertEqual(tasteAffinity(mine: p, theirs: p), 1.0, accuracy: 0.0001)
    }

    func testNoOverlapScoresZero() {
        let mine   = profile(tracks: ["a1"], artists: ["Paramore"])
        let theirs = profile(tracks: ["b1"], artists: ["Geese"])
        XCTAssertEqual(tasteAffinity(mine: mine, theirs: theirs), 0.0, accuracy: 0.0001)
    }

    func testEmptyOtherSideScoresZeroRatherThanCrashing() {
        let mine = profile(tracks: ["a1"], artists: ["Paramore"])
        XCTAssertEqual(tasteAffinity(mine: mine, theirs: TasteProfile()), 0.0)
    }

    /// Normalizing by THEIR size (not Jaccard) is the deliberate choice — a
    /// person with a tiny library whose every track I also play is a perfect
    /// match, and Jaccard would wrongly punish them for being small.
    func testNormalizesByTheirSetSizeNotUnion() {
        var mine = TasteProfile()
        for i in 0..<100 { mine.add(catalogId: "t\(i)", artist: "Artist\(i)") }
        var theirs = TasteProfile()
        theirs.add(catalogId: "t0", artist: "Artist0")

        XCTAssertEqual(tasteAffinity(mine: mine, theirs: theirs), 1.0, accuracy: 0.0001)
    }

    func testArtistOverlapOutweighsTrackOverlap() {
        var mine = TasteProfile()
        mine.add(catalogId: "mine1", artist: "Shared Artist")

        // Shares the artist but no track.
        var artistMatch = TasteProfile()
        artistMatch.add(catalogId: "other1", artist: "Shared Artist")

        // Shares a track but no artist. Build by hand so the two dimensions
        // can be varied independently.
        let trackMatch = TasteProfile(trackIds: ["mine1"], artists: ["someone else"])

        XCTAssertGreaterThan(
            tasteAffinity(mine: mine, theirs: artistMatch),
            tasteAffinity(mine: mine, theirs: trackMatch)
        )
    }

    func testFallsBackToSingleDimensionWhenOtherIsAbsent() {
        let mine = TasteProfile(trackIds: ["t1"], artists: ["paramore"])
        // Artists only — should score on artists alone, not be capped at 0.7.
        let artistsOnly = TasteProfile(trackIds: [], artists: ["paramore"])
        XCTAssertEqual(tasteAffinity(mine: mine, theirs: artistsOnly), 1.0, accuracy: 0.0001)

        // Tracks only — likewise not capped at 0.3.
        let tracksOnly = TasteProfile(trackIds: ["t1"], artists: [])
        XCTAssertEqual(tasteAffinity(mine: mine, theirs: tracksOnly), 1.0, accuracy: 0.0001)
    }

    // MARK: ranking

    private func person(_ uid: String, artists: [String], skew: Double = 1) -> PersonTaste {
        var p = TasteProfile()
        for a in artists { p.add(catalogId: nil, artist: a) }
        return PersonTaste(uid: uid, username: uid, profile: p, skew: skew)
    }

    func testRanksBestMatchFirst() {
        let mine = profile(artists: ["Paramore", "Geese", "Wolf Alice"])
        let ranked = rankPeople(
            mine: mine,
            candidates: [
                person("weak",   artists: ["Paramore", "Unrelated1", "Unrelated2", "Unrelated3"]),
                person("strong", artists: ["Paramore", "Geese"]),
            ],
            limit: 10
        )
        XCTAssertEqual(ranked.map(\.uid), ["strong", "weak"])
    }

    func testSkewMultipliesAffinity() {
        let mine = profile(artists: ["Paramore"])
        let ranked = rankPeople(
            mine: mine,
            candidates: [
                person("plain",  artists: ["Paramore", "Other"], skew: 1),
                person("boosted", artists: ["Paramore", "Other"], skew: 3),
            ],
            limit: 10
        )
        XCTAssertEqual(ranked.first?.uid, "boosted")
        // Affinity itself is untouched by the skew — only weight changes.
        XCTAssertEqual(ranked[0].affinity, ranked[1].affinity, accuracy: 0.0001)
        XCTAssertEqual(ranked[0].weight, ranked[1].weight * 3, accuracy: 0.0001)
    }

    func testDropsPeopleBelowTheQualityFloor() {
        var mine = TasteProfile()
        mine.add(catalogId: nil, artist: "Paramore")
        // 1 shared artist out of 200 — far below minimumTasteAffinity.
        var noiseArtists = ["Paramore"]
        for i in 0..<200 { noiseArtists.append("Noise\(i)") }

        let ranked = rankPeople(mine: mine, candidates: [person("noise", artists: noiseArtists)], limit: 10)
        XCTAssertTrue(ranked.isEmpty)
    }

    /// An empty profile means "no data", not "bad match". Stage-1 taste comes
    /// only from spotlights, and most people have never spotlit anything — so
    /// dropping them made the `nearby` and `admirers` pools collapse back onto
    /// whoever the user already follows.
    func testKeepsCandidatesWithNoDataAtBaseline() {
        let mine = profile(artists: ["Paramore"])
        let unknown = PersonTaste(uid: "stranger", username: "stranger", profile: TasteProfile())
        let ranked = rankPeople(mine: mine, candidates: [unknown], limit: 10)

        XCTAssertEqual(ranked.map(\.uid), ["stranger"])
        XCTAssertEqual(ranked.first?.affinity ?? -1, unknownTasteAffinity, accuracy: 0.0001)
    }

    /// Unknowns fill leftover slots — they must never displace a real match.
    func testUnknownsRankBelowRealMatches() {
        let mine = profile(artists: ["Paramore", "Geese"])
        let ranked = rankPeople(
            mine: mine,
            candidates: [
                PersonTaste(uid: "stranger", username: "stranger", profile: TasteProfile()),
                person("match", artists: ["Paramore", "Geese"]),
            ],
            limit: 10
        )
        XCTAssertEqual(ranked.map(\.uid), ["match", "stranger"])
    }

    /// The quality floor still applies to anyone we *do* have data on — keeping
    /// unknowns must not become a back door for known non-matches.
    func testStillDropsMeasuredNonMatches() {
        var mine = TasteProfile()
        mine.add(catalogId: nil, artist: "Paramore")
        var noiseArtists = ["Paramore"]
        for i in 0..<200 { noiseArtists.append("Noise\(i)") }

        let ranked = rankPeople(
            mine: mine,
            candidates: [
                person("noise", artists: noiseArtists),
                PersonTaste(uid: "stranger", username: "stranger", profile: TasteProfile()),
            ],
            limit: 10
        )
        XCTAssertEqual(ranked.map(\.uid), ["stranger"],
                       "no data stays; measured non-overlap is still dropped")
    }

    func testEmptyOwnProfileRanksNobody() {
        let ranked = rankPeople(
            mine: TasteProfile(),
            candidates: [person("someone", artists: ["Paramore"])],
            limit: 10
        )
        XCTAssertTrue(ranked.isEmpty, "with no taste of our own there is nothing to match against")
    }

    func testRespectsLimit() {
        let mine = profile(artists: ["Paramore"])
        let candidates = (0..<10).map { person("u\($0)", artists: ["Paramore"]) }
        XCTAssertEqual(rankPeople(mine: mine, candidates: candidates, limit: 3).count, 3)
    }

    /// Regenerating with unchanged inputs must not reorder, or the user's
    /// playlist churns for no reason.
    func testTiedPeopleOrderDeterministically() {
        let mine = profile(artists: ["Paramore"])
        let candidates = [person("zeta", artists: ["Paramore"]), person("alpha", artists: ["Paramore"])]
        let first  = rankPeople(mine: mine, candidates: candidates, limit: 10)
        let second = rankPeople(mine: mine, candidates: candidates.reversed(), limit: 10)
        XCTAssertEqual(first.map(\.uid), ["alpha", "zeta"])
        XCTAssertEqual(first.map(\.uid), second.map(\.uid))
    }
}
