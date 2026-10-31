import XCTest
@testable import NodalongKit

final class PlaylistGenerationTests: XCTestCase {

    private func contribution(
        _ catalogId: String,
        artist: String = "Some Artist",
        uid: String = "friend1",
        username: String = "friend1",
        weight: Double = 1,
        signal: TrackSignal = .recentPlay
    ) -> TrackContribution {
        TrackContribution(
            catalogId: catalogId,
            artist: artist,
            personUid: uid,
            personUsername: username,
            personWeight: weight,
            signal: signal
        )
    }

    // MARK: filtering

    func testExcludesTracksTheUserAlreadyHas() {
        let picked = selectTracks(
            contributions: [contribution("known"), contribution("new")],
            excluding: ["known"]
        )
        XCTAssertEqual(picked.map(\.catalogId), ["new"])
    }

    func testDropsEmptyCatalogIdsAndZeroWeightPeople() {
        let picked = selectTracks(
            contributions: [
                contribution(""),
                contribution("zeroWeight", weight: 0),
                contribution("good"),
            ],
            excluding: []
        )
        XCTAssertEqual(picked.map(\.catalogId), ["good"])
    }

    // MARK: per-lens signal weights

    /// Regression test for the reported bug: four lenses drawing on the same one
    /// person produced four byte-identical playlists, because a lens only chose
    /// the *pool* and applied no opinion of its own to the tracks.
    func testSignalWeightsChangeWhichTracksRankFirst() {
        let contributions = [
            contribution("spotlit", artist: "A", signal: .spotlight),
            contribution("replayed", artist: "B", signal: .replayedRecent),
        ]

        let circle = selectTracks(
            contributions: contributions,
            excluding: [],
            signalWeights: PlaylistLens.circle.signalWeights
        )
        let admirers = selectTracks(
            contributions: contributions,
            excluding: [],
            signalWeights: PlaylistLens.admirers.signalWeights
        )

        XCTAssertEqual(circle.first?.catalogId, "spotlit",
                       "the circle lens leans on deliberate picks")
        XCTAssertEqual(admirers.first?.catalogId, "replayed",
                       "the admirers lens leans on what people come back to")
    }

    /// The `nearby` lens is about what is being played right now, so an ordinary
    /// recent play must be able to beat a spotlight there — the exact inversion
    /// of `circle`.
    func testNearbyFavoursRecentPlaysOverSpotlights() {
        let contributions = [
            contribution("spotlit", artist: "A", signal: .spotlight),
            contribution("nowPlaying", artist: "B", signal: .recentPlay),
            contribution("nowPlaying2", artist: "B", signal: .recentPlay),
        ]

        let nearby = selectTracks(
            contributions: contributions,
            excluding: [],
            signalWeights: PlaylistLens.nearby.signalWeights
        )
        XCTAssertEqual(nearby.first?.catalogId, "nowPlaying")
    }

    /// Omitting `signalWeights` must behave exactly as it did before the
    /// parameter existed, or every existing playlist silently changes shape.
    func testDefaultSignalWeightsAreBalanced() {
        let contributions = [
            contribution("a", artist: "A", signal: .spotlight),
            contribution("b", artist: "B", signal: .replayedRecent),
            contribution("c", artist: "C", signal: .recentPlay),
        ]
        let implicit = selectTracks(contributions: contributions, excluding: [])
        let explicit = selectTracks(
            contributions: contributions, excluding: [], signalWeights: .balanced
        )
        XCTAssertEqual(implicit.map(\.catalogId), explicit.map(\.catalogId))
        XCTAssertEqual(implicit.map(\.catalogId), ["a", "b", "c"])
    }

    /// The four lenses must not all agree. This is the property that was broken.
    func testLensesDoNotAllProduceTheSameOrdering() {
        let contributions = [
            contribution("spotlit",  artist: "A", signal: .spotlight),
            contribution("replayed", artist: "B", signal: .replayedRecent),
            contribution("played",   artist: "C", signal: .recentPlay),
            contribution("played2",  artist: "D", signal: .recentPlay),
        ]

        let orderings = Set(PlaylistLens.allCases.map { lens in
            selectTracks(
                contributions: contributions,
                excluding: [],
                signalWeights: lens.signalWeights
            ).map(\.catalogId).joined(separator: ",")
        })

        XCTAssertGreaterThan(orderings.count, 1,
                             "lenses drawing on the same people must still differ")
    }

    // MARK: signal weighting

    func testSpotlightOutranksReplayOutranksPlainPlay() {
        let picked = selectTracks(
            contributions: [
                contribution("play",      artist: "A", signal: .recentPlay),
                contribution("spotlight", artist: "B", signal: .spotlight),
                contribution("replay",    artist: "C", signal: .replayedRecent),
            ],
            excluding: []
        )
        XCTAssertEqual(picked.map(\.catalogId), ["spotlight", "replay", "play"])
    }

    func testPersonWeightScalesTheScore() {
        let picked = selectTracks(
            contributions: [
                contribution("fromWeakMatch",   artist: "A", uid: "weak",   weight: 0.1, signal: .spotlight),
                contribution("fromStrongMatch", artist: "B", uid: "strong", weight: 1.0, signal: .recentPlay),
            ],
            excluding: []
        )
        // 1.0 × 1.0 beats 0.1 × 3.0 — who it came from matters more than the signal.
        XCTAssertEqual(picked.first?.catalogId, "fromStrongMatch")
    }

    /// The collaborative-filtering core: several people independently loving a
    /// track should beat one person's outlier, with no special-case boost.
    func testCorroborationEmergesFromSummingContributions() {
        let picked = selectTracks(
            contributions: [
                contribution("solo",   artist: "A", uid: "u1", signal: .replayedRecent),
                contribution("shared", artist: "B", uid: "u1", signal: .recentPlay),
                contribution("shared", artist: "B", uid: "u2", signal: .recentPlay),
                contribution("shared", artist: "B", uid: "u3", signal: .recentPlay),
            ],
            excluding: []
        )
        XCTAssertEqual(picked.first?.catalogId, "shared")
        XCTAssertEqual(picked.first?.contributorCount, 3)
    }

    func testContributorCountCountsDistinctPeopleNotContributions() {
        let picked = selectTracks(
            contributions: [
                contribution("t", uid: "u1", signal: .recentPlay),
                contribution("t", uid: "u1", signal: .spotlight),
            ],
            excluding: []
        )
        XCTAssertEqual(picked.first?.contributorCount, 1)
    }

    // MARK: attribution

    func testCreditsTheStrongestSingleContributor() {
        let picked = selectTracks(
            contributions: [
                contribution("t", uid: "quiet", username: "quiet", weight: 0.2, signal: .recentPlay),
                contribution("t", uid: "loud",  username: "loud",  weight: 1.0, signal: .spotlight),
            ],
            excluding: []
        )
        XCTAssertEqual(picked.first?.addedByUid, "loud")
        XCTAssertEqual(picked.first?.addedByUsername, "loud")
    }

    // MARK: artist diversity

    func testCapsTracksPerArtist() {
        let picked = selectTracks(
            contributions: (0..<10).map { contribution("t\($0)", artist: "One Artist") },
            excluding: [],
            maxPerArtist: 2
        )
        XCTAssertEqual(picked.count, 2)
    }

    /// A featured credit must not sneak past the cap as a "different" artist.
    func testArtistCapUsesPrimaryArtistNormalization() {
        let picked = selectTracks(
            contributions: [
                contribution("t1", artist: "Dahi"),
                contribution("t2", artist: "Dahi & Childish Gambino"),
                contribution("t3", artist: "Dahi feat. Kendrick Lamar"),
            ],
            excluding: [],
            maxPerArtist: 2
        )
        XCTAssertEqual(picked.count, 2)
    }

    func testCapKeepsTheArtistsBestTracks() {
        let picked = selectTracks(
            contributions: [
                contribution("weak",   artist: "A", signal: .recentPlay),
                contribution("strong", artist: "A", signal: .spotlight),
            ],
            excluding: [],
            maxPerArtist: 1
        )
        XCTAssertEqual(picked.map(\.catalogId), ["strong"])
    }

    func testCapDoesNotBlockOtherArtists() {
        let picked = selectTracks(
            contributions: [
                contribution("a1", artist: "A"), contribution("a2", artist: "A"),
                contribution("a3", artist: "A"), contribution("b1", artist: "B"),
            ],
            excluding: [],
            maxPerArtist: 2
        )
        XCTAssertEqual(Set(picked.map(\.catalogId)), ["a1", "a2", "b1"])
    }

    // MARK: limits and determinism

    func testRespectsTrackLimit() {
        let picked = selectTracks(
            contributions: (0..<50).map { contribution("t\($0)", artist: "Artist\($0)") },
            excluding: [],
            limit: 25
        )
        XCTAssertEqual(picked.count, 25)
    }

    func testZeroLimitReturnsNothing() {
        XCTAssertTrue(selectTracks(contributions: [contribution("t")], excluding: [], limit: 0).isEmpty)
    }

    func testEmptyInputReturnsNothing() {
        XCTAssertTrue(selectTracks(contributions: [], excluding: []).isEmpty)
    }

    /// Regenerating with unchanged inputs must produce an unchanged playlist.
    func testTiedTracksOrderDeterministically() {
        let contributions = [
            contribution("zeta",  artist: "A"),
            contribution("alpha", artist: "B"),
        ]
        let first  = selectTracks(contributions: contributions, excluding: [])
        let second = selectTracks(contributions: contributions.reversed(), excluding: [])
        XCTAssertEqual(first.map(\.catalogId), ["alpha", "zeta"])
        XCTAssertEqual(first.map(\.catalogId), second.map(\.catalogId))
    }

    func testEverythingAlreadyHeardYieldsEmptyRatherThanNoise() {
        let picked = selectTracks(
            contributions: [contribution("t1"), contribution("t2")],
            excluding: ["t1", "t2"]
        )
        XCTAssertTrue(picked.isEmpty)
    }
}
