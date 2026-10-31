import XCTest
@testable import NodalongKit

/// The taste lens's two pure stages. This is where its scoring bugs would live
/// — everything either side is network or Firestore.
final class TasteDiscoveryTests: XCTestCase {

    // MARK: - Fixtures

    private func library(
        _ catalogId: String,
        title: String = "Track",
        artist: String,
        isrc: String? = nil,
        genres: [String] = []
    ) -> LibraryTrackDoc {
        LibraryTrackDoc(
            catalogId: catalogId, title: title, artist: artist, album: "Album",
            artwork: "", uri: "u\(catalogId)", sourceService: .appleMusic,
            isrc: isrc, duration: nil, trackNumber: nil, albumReleaseDate: nil,
            genres: genres, isExplicit: false, savedAt: 0
        )
    }

    private func post(
        _ catalogId: String,
        title: String = "Track",
        artist: String,
        isrc: String? = nil,
        replayCount: Int = 0
    ) -> Post {
        Post(
            id: catalogId, uid: "u", username: "u", avatarEmoji: nil,
            avatarCharacter: nil, avatarColor: nil, catalogId: catalogId,
            title: title, artist: artist, album: "Album", artwork: "",
            uri: "u\(catalogId)", isrc: isrc, sourceService: .appleMusic,
            nods: 0, replayCount: replayCount, createdAt: 0
        )
    }

    private func spotlight(_ catalogId: String, title: String = "Track", artist: String) -> SpotlightTrack {
        SpotlightTrack(
            trackId: catalogId, title: title, artist: artist, album: "Album",
            artwork: "", uri: "u\(catalogId)", spotlitAt: 0,
            catalogId: catalogId, sourceService: .appleMusic
        )
    }

    private func song(
        title: String,
        artist: String,
        isrc: String? = nil,
        genres: [String] = []
    ) -> Song {
        Song(
            id: "\(title)-\(artist)", title: title, artist: artist, album: "Album",
            artwork: "", trackId: "\(title)-\(artist)", uri: "uri",
            sourceService: .appleMusic, isrc: isrc, genres: genres
        )
    }

    // MARK: - Stage 0: seeding

    /// The whole argument for this feature over Apple's own recommender: a
    /// deliberate pick has to outweigh a background play.
    func testSpotlitArtistOutranksMerelyPlayedArtist() {
        let seeds = buildTasteSeeds(
            library: [],
            recents: [post("p1", artist: "Played Artist")],
            spotlights: [spotlight("s1", artist: "Spotlit Artist")]
        )
        XCTAssertEqual(seeds.artists.first?.displayName, "Spotlit Artist")
        XCTAssertGreaterThan(seeds.artists[0].weight, seeds.artists[1].weight)
    }

    func testReplayOutweighsPlainPlay() {
        let seeds = buildTasteSeeds(
            library: [],
            recents: [
                post("p1", artist: "Replayed", replayCount: 3),
                post("p2", artist: "Played")
            ],
            spotlights: []
        )
        XCTAssertEqual(seeds.artists.first?.displayName, "Replayed")
    }

    /// Featured credits must collapse onto the primary artist, or the same
    /// artist seeds twice at half strength each.
    func testFeaturedCreditsCollapseOntoPrimaryArtist() {
        let seeds = buildTasteSeeds(
            library: [
                library("a", artist: "Kanye West"),
                library("b", artist: "Kanye West & Dwele")
            ],
            recents: [], spotlights: []
        )
        XCTAssertEqual(seeds.artists.count, 1)
        XCTAssertEqual(seeds.artists[0].key, "kanye west")
        XCTAssertEqual(seeds.artists[0].weight, TasteSignal.shelfSave.weight * 2)
    }

    func testArtistLimitIsApplied() {
        let tracks = (0..<20).map { library("c\($0)", artist: "Artist \($0)") }
        XCTAssertEqual(buildTasteSeeds(library: tracks, recents: [], spotlights: [], artistLimit: 5).artists.count, 5)
    }

    func testEmptyListeningProducesEmptySeeds() {
        XCTAssertTrue(buildTasteSeeds(library: [], recents: [], spotlights: []).isEmpty)
    }

    // MARK: - Heard exclusion

    /// A MusicKit candidate has no catalogId, so ISRC and title+artist are what
    /// actually do the excluding.
    func testHeardMatchesOnIsrcWithNoCatalogId() {
        let seeds = buildTasteSeeds(
            library: [library("a", title: "Song", artist: "Artist", isrc: "GBABC1234567")],
            recents: [], spotlights: []
        )
        XCTAssertTrue(seeds.hasHeard(catalogId: nil, isrc: "GBABC1234567", title: "Different", artist: "Other"))
    }

    func testHeardMatchesOnTitleAndArtistWhenIsrcIsMissing() {
        let seeds = buildTasteSeeds(
            library: [library("a", title: "Marianne", artist: "Fontaines D.C.")],
            recents: [], spotlights: []
        )
        XCTAssertTrue(seeds.hasHeard(catalogId: nil, isrc: nil, title: "Marianne", artist: "Fontaines D.C."))
        XCTAssertFalse(seeds.hasHeard(catalogId: nil, isrc: nil, title: "Starburster", artist: "Fontaines D.C."))
    }

    /// The normalization has to reach across store suffixes and featured
    /// credits, or the same recording sneaks back in under a different label.
    func testHeardMatchIgnoresRemasterSuffixAndFeaturedCredit() {
        let seeds = buildTasteSeeds(
            library: [library("a", title: "Song", artist: "Artist")],
            recents: [], spotlights: []
        )
        XCTAssertTrue(seeds.hasHeard(
            catalogId: nil, isrc: nil,
            title: "Song - Remastered 2011", artist: "Artist & Someone Else"
        ))
    }

    // MARK: - Stage 1: candidate artists

    /// Corroboration is the core of the ranking: reached from two seeds beats
    /// reached from one.
    func testArtistReachedFromTwoSeedsOutranksOneReachedFromASingleSeed() {
        let a = SeededArtist(key: "a", displayName: "A", weight: 1)
        let b = SeededArtist(key: "b", displayName: "B", weight: 1)
        let ranked = rankCandidateArtists(
            similarBySeed: [
                (a, [("shared", "Shared"), ("only-a", "Only A")]),
                (b, [("shared", "Shared")])
            ],
            excluding: [], limit: 10
        )
        XCTAssertEqual(ranked.first?.id, "shared")
        XCTAssertEqual(ranked.first?.score, 2)
        XCTAssertEqual(ranked.first?.seedNames, ["A", "B"])
    }

    /// An artist I already listen to is not a discovery, however strongly the
    /// similarity graph points at them.
    func testArtistsIAlreadyListenToAreExcluded() {
        let seed = SeededArtist(key: "mine", displayName: "Mine", weight: 5)
        let ranked = rankCandidateArtists(
            similarBySeed: [(seed, [("known", "Known Artist"), ("new", "New Artist")])],
            excluding: ["known artist"], limit: 10
        )
        XCTAssertEqual(ranked.map(\.id), ["new"])
    }

    func testCandidateArtistsAreCappedAndOrderedByWeightedSeed() {
        let heavy = SeededArtist(key: "h", displayName: "Heavy", weight: 10)
        let light = SeededArtist(key: "l", displayName: "Light", weight: 1)
        let ranked = rankCandidateArtists(
            similarBySeed: [(heavy, [("x", "X")]), (light, [("y", "Y")])],
            excluding: [], limit: 1
        )
        XCTAssertEqual(ranked.map(\.id), ["x"])
    }

    // MARK: - Known-artist exclusion

    /// 🔴 The regression test for the bug behind "it shows a lot of artists I
    /// already listen to."
    ///
    /// `artists` is capped at the seed limit because expanding the similarity
    /// graph from an entire library would be enormous. `knownArtistKeys` used
    /// to be derived from that same truncated list, so every artist past the
    /// cutoff — the overwhelming majority of a real library — was eligible to
    /// be handed back as a "discovery". Seeding and exclusion are different
    /// jobs and must not share a cut.
    func testKnownArtistsBeyondTheSeedLimitAreStillExcluded() {
        // 20 artists, one track each, so weights are equal and the seed cut
        // is purely the limit doing its work.
        let tracks = (0..<20).map { library("c\($0)", artist: "Artist\($0)") }
        let seeds = buildTasteSeeds(library: tracks, recents: [], spotlights: [], artistLimit: 8)

        XCTAssertEqual(seeds.artists.count, 8, "seeding is still capped")
        XCTAssertEqual(seeds.knownArtistKeys.count, 20, "but every artist is still 'known'")

        // Whichever artist fell outside the seed cut must still be excluded.
        let seeded = Set(seeds.artists.map(\.key))
        guard let beyondCut = (0..<20).map({ "artist\($0)" }).first(where: { !seeded.contains($0) }) else {
            return XCTFail("expected at least one artist past the seed cut")
        }

        let ranked = rankCandidateArtists(
            similarBySeed: [(
                seed: SeededArtist(key: "seed", displayName: "Seed", weight: 1),
                similar: [(id: "id1", name: beyondCut), (id: "id2", name: "Genuinely New")]
            )],
            excluding: seeds.knownArtistKeys,
            limit: 10
        )
        XCTAssertEqual(ranked.map(\.name), ["Genuinely New"],
                       "an artist already in the library is not a discovery, seeded or not")
    }

    /// A directly-constructed `TasteSeeds` (no `allArtistKeys`) must still
    /// exclude its own seeds, so the new field can't silently weaken callers
    /// that don't set it.
    func testDirectlyConstructedSeedsStillExcludeTheirOwnArtists() {
        let seeds = TasteSeeds(
            artists: [SeededArtist(key: "known", displayName: "Known", weight: 1)],
            genreWeights: [:], heardCatalogIds: [], heardIsrcs: [], heardTitleArtist: []
        )
        XCTAssertEqual(seeds.knownArtistKeys, ["known"])
    }

    // MARK: - Apple Music library as a source

    /// 🔴 The remaining hole in the exclusion set: an artist you own on Apple
    /// Music but never saved to your Nodalong Shelf was still eligible to be
    /// suggested as a "discovery". The library is read live at generation
    /// time and never persisted, so it can only close this here.
    func testAppleLibraryArtistsAreExcludedFromDiscovery() {
        let seeds = buildTasteSeeds(
            library: [library("c1", artist: "Shelf Artist")],
            recents: [], spotlights: [],
            appleLibrary: [song(title: "Owned", artist: "Apple Library Artist", isrc: "I9")]
        )
        XCTAssertTrue(seeds.knownArtistKeys.contains("apple library artist"))
        XCTAssertTrue(seeds.hasHeard(catalogId: nil, isrc: "I9", title: "Owned", artist: "Apple Library Artist"))
    }

    func testAppleLibrarySeedsWeighLessThanAShelfSave() {
        let seeds = buildTasteSeeds(
            library: [library("c1", artist: "Kept")],
            recents: [], spotlights: [],
            appleLibrary: [song(title: "Owned", artist: "Owned Artist", isrc: "I9")]
        )
        // Both seed, but a decision made in this app outranks a decade-old
        // Apple Music save.
        XCTAssertEqual(seeds.artists.map(\.displayName), ["Kept", "Owned Artist"])
        XCTAssertGreaterThan(TasteSignal.shelfSave.weight, TasteSignal.appleLibrary.weight)
        XCTAssertGreaterThan(TasteSignal.appleLibrary.weight, TasteSignal.play.weight)
    }

    // MARK: - Genre-scoped seeding

    func testSeedGenreNarrowsWhichArtistsSeedTheExpansion() {
        let tracks = [
            library("c1", artist: "Rapper", genres: ["Hip-Hop"]),
            library("c2", artist: "Guitarist", genres: ["Rock"])
        ]
        let seeds = buildTasteSeeds(library: tracks, recents: [], spotlights: [], seedGenre: "Hip-Hop")
        XCTAssertEqual(seeds.artists.map(\.displayName), ["Rapper"])
    }

    /// 🔴 The property a genre-scoped run is most likely to break: narrowing
    /// the seeds must NOT narrow what counts as already-heard or
    /// already-known. Otherwise a hip-hop run would happily suggest an artist
    /// you listen to constantly in another genre — reintroducing the
    /// exclusion bug through a side door.
    func testSeedGenreDoesNotNarrowHeardOrKnown() {
        let tracks = [
            library("c1", title: "Bars", artist: "Rapper", isrc: "I1", genres: ["Hip-Hop"]),
            library("c2", title: "Riff", artist: "Guitarist", isrc: "I2", genres: ["Rock"])
        ]
        let seeds = buildTasteSeeds(library: tracks, recents: [], spotlights: [], seedGenre: "Hip-Hop")

        XCTAssertTrue(seeds.knownArtistKeys.contains("guitarist"),
                      "an artist from another genre is still someone you listen to")
        XCTAssertTrue(seeds.hasHeard(catalogId: "c2", isrc: "I2", title: "Riff", artist: "Guitarist"),
                      "a track from another genre is still heard")
    }

    /// Recents and spotlights carry no genre, so they can't be judged in a
    /// scoped run — excluded from seeding rather than guessed at, but still
    /// fully counted as heard and known.
    func testUngenredSourcesStillCountAsHeardInAScopedRun() {
        let seeds = buildTasteSeeds(
            library: [library("c1", artist: "Rapper", genres: ["Hip-Hop"])],
            recents: [post("c9", title: "Played", artist: "Someone Else", isrc: "I9")],
            spotlights: [],
            seedGenre: "Hip-Hop"
        )
        XCTAssertEqual(seeds.artists.map(\.displayName), ["Rapper"], "an ungenred play does not seed a scoped run")
        XCTAssertTrue(seeds.knownArtistKeys.contains("someone else"))
        XCTAssertTrue(seeds.hasHeard(catalogId: "c9", isrc: "I9", title: "Played", artist: "Someone Else"))
    }

    // MARK: - Stage 2: track selection

    func testAlreadyHeardTracksAreDropped() {
        let seeds = buildTasteSeeds(
            library: [library("a", title: "Known", artist: "Someone", isrc: "ISRC1")],
            recents: [], spotlights: []
        )
        let picked = selectTasteTracks(
            candidates: [
                TasteCandidate(song: song(title: "Known", artist: "Someone", isrc: "ISRC1"), artistScore: 5, rank: 0),
                TasteCandidate(song: song(title: "Fresh", artist: "Newcomer", isrc: "ISRC2"), artistScore: 1, rank: 0)
            ],
            seeds: seeds
        )
        XCTAssertEqual(picked.map(\.song.title), ["Fresh"])
    }

    /// One artist with many tracks yields at most two, and prefers a deep cut
    /// (album track outside their top songs) over their popular ones.
    func testOneArtistYieldsAtMostTwoAndPrefersDeepCuts() {
        let seeds = buildTasteSeeds(library: [library("x", artist: "Me")], recents: [], spotlights: [])
        var candidates = (0..<10).map {
            TasteCandidate(song: song(title: "Hit\($0)", artist: "Prolific", isrc: "H\($0)"), artistScore: 10, rank: $0)
        }
        candidates.append(TasteCandidate(song: song(title: "Deep1", artist: "Prolific", isrc: "D1"), artistScore: 10, rank: tasteAlbumTrackRank))
        candidates.append(TasteCandidate(song: song(title: "Deep2", artist: "Prolific", isrc: "D2"), artistScore: 10, rank: tasteAlbumTrackRank))
        let picked = selectTasteTracks(candidates: candidates, seeds: seeds)
        XCTAssertEqual(picked.count, 2, "never more than two from one artist")
        XCTAssertEqual(Set(picked.map(\.song.title)), ["Deep1", "Deep2"])
    }

    func testSignatureTracksAreTheLastResort() {
        let seeds = buildTasteSeeds(library: [library("x", artist: "Me")], recents: [], spotlights: [])
        let candidates = [
            TasteCandidate(song: song(title: "Signature", artist: "A", isrc: "S"), artistScore: 5, rank: 0),
            TasteCandidate(song: song(title: "Tail", artist: "A", isrc: "T"), artistScore: 5, rank: 8)
        ]
        let picked = selectTasteTracks(candidates: candidates, seeds: seeds)
        XCTAssertEqual(picked.first?.song.title, "Tail")
    }

    /// The reported bug: 12 artists × 2 tracks. A full list now spreads over
    /// many artists, and only the first few drawn may carry a second track.
    func testFullListSpreadsAcrossManyArtists() {
        let seeds = buildTasteSeeds(library: [library("x", artist: "Me")], recents: [], spotlights: [])
        var candidates: [TasteCandidate] = []
        for a in 0..<40 {
            for t in 0..<3 {
                candidates.append(TasteCandidate(
                    song: song(title: "T\(a)-\(t)", artist: "Artist\(a)", isrc: "I\(a)-\(t)"),
                    artistScore: 10, rank: 5 + t))
            }
        }
        for seed in UInt64(1)...20 {
            let picked = selectTasteTracks(candidates: candidates, seeds: seeds, shuffleSeed: seed)
            XCTAssertEqual(picked.count, generatedPlaylistTrackLimit)
            let perArtist = Dictionary(grouping: picked, by: \.artistKey).mapValues(\.count)
            XCTAssertLessThanOrEqual(perArtist.values.max() ?? 0, 2)
            XCTAssertLessThanOrEqual(perArtist.values.filter { $0 == 2 }.count, tasteDoubleSlotArtists)
            XCTAssertGreaterThanOrEqual(perArtist.count, 18, "seed \(seed)")
        }
    }

    /// ↻ must reach artists the first build didn't — the old pool never could.
    func testDifferentSeedsReachDifferentArtists() {
        let seeds = buildTasteSeeds(library: [library("x", artist: "Me")], recents: [], spotlights: [])
        let candidates = (0..<40).map {
            TasteCandidate(song: song(title: "T\($0)", artist: "A\($0)", isrc: "I\($0)"), artistScore: 10, rank: 5)
        }
        let a = Set(selectTasteTracks(candidates: candidates, seeds: seeds, shuffleSeed: 1).map(\.artistKey))
        let b = Set(selectTasteTracks(candidates: candidates, seeds: seeds, shuffleSeed: 2).map(\.artistKey))
        XCTAssertNotEqual(a, b)
    }

    func testSignatureTracksArePenalisedAndDeeperOnesAreFlat() {
        XCTAssertEqual(discoveryPositionWeight(rank: 0), tasteFamiliarPenalty)
        XCTAssertEqual(discoveryPositionWeight(rank: tasteFamiliarRankCutoff - 1), tasteFamiliarPenalty)
        // Past the cutoff every rank is treated alike: position is a
        // popularity signal, not a quality one, so there's no reason to
        // believe track 12 beats track 5.
        XCTAssertEqual(discoveryPositionWeight(rank: tasteFamiliarRankCutoff), 1.0)
        XCTAssertEqual(discoveryPositionWeight(rank: 29), 1.0)
    }

    // MARK: - Seeded reshuffle

    /// No seed reproduces the original fully-deterministic behaviour — which
    /// is what the weekly auto-refresh relies on, and what every other test
    /// in this file pins.
    func testNoSeedIsDeterministic() {
        let seeds = buildTasteSeeds(library: [library("x", artist: "Me")], recents: [], spotlights: [])
        let candidates = (0..<20).map {
            TasteCandidate(song: song(title: "T\($0)", artist: "A\($0)", isrc: "I\($0)"), artistScore: 10, rank: 5)
        }
        let a = selectTasteTracks(candidates: candidates, seeds: seeds)
        let b = selectTasteTracks(candidates: candidates, seeds: seeds)
        XCTAssertEqual(a.map(\.song.title), b.map(\.song.title))
    }

    func testSameSeedProducesSameOrderAndDifferentSeedsDiffer() {
        let seeds = buildTasteSeeds(library: [library("x", artist: "Me")], recents: [], spotlights: [])
        let candidates = (0..<40).map {
            TasteCandidate(song: song(title: "T\($0)", artist: "A\($0)", isrc: "I\($0)"), artistScore: 10, rank: 5)
        }
        let first  = selectTasteTracks(candidates: candidates, seeds: seeds, shuffleSeed: 42)
        let again  = selectTasteTracks(candidates: candidates, seeds: seeds, shuffleSeed: 42)
        let other  = selectTasteTracks(candidates: candidates, seeds: seeds, shuffleSeed: 99)

        XCTAssertEqual(first.map(\.song.title), again.map(\.song.title),
                       "a built playlist must be reproducible from its seed")
        XCTAssertNotEqual(first.map(\.song.title), other.map(\.song.title),
                          "↻ must genuinely produce a different list")
    }

    /// The draw is weighted, so a heavily-corroborated artist should come first
    /// almost always — statistical now, since a weighted draw can (rarely) let an
    /// outlier lead.
    func testShuffleMostlyKeepsAStrongScoreGap() {
        let seeds = buildTasteSeeds(library: [library("x", artist: "Me")], recents: [], spotlights: [])
        let candidates = [
            TasteCandidate(song: song(title: "Strong", artist: "Corroborated", isrc: "I1"), artistScore: 100, rank: 5),
            TasteCandidate(song: song(title: "Weak", artist: "Outlier", isrc: "I2"), artistScore: 1, rank: 5)
        ]
        var strongFirst = 0
        for seed in UInt64(0)..<200 {
            let picked = selectTasteTracks(candidates: candidates, seeds: seeds, shuffleSeed: seed)
            if picked.first?.song.title == "Strong" { strongFirst += 1 }
        }
        XCTAssertGreaterThanOrEqual(strongFirst, 190)
    }

    /// Genre agreement should nudge, not decide — Apple's similarity already
    /// did the hard part.
    func testGenreAgreementBreaksTiesButDoesNotOverturnArtistScore() {
        let seeds = buildTasteSeeds(
            library: [library("a", artist: "Me", genres: ["Hip-Hop"])],
            recents: [], spotlights: []
        )
        let tie = selectTasteTracks(
            candidates: [
                TasteCandidate(song: song(title: "Off", artist: "A", isrc: "I1"), artistScore: 5, rank: 0),
                TasteCandidate(song: song(title: "On", artist: "B", isrc: "I2", genres: ["Hip-Hop"]), artistScore: 5, rank: 0)
            ],
            seeds: seeds
        )
        XCTAssertEqual(tie.first?.song.title, "On")

        let outranked = selectTasteTracks(
            candidates: [
                TasteCandidate(song: song(title: "Strong", artist: "A", isrc: "I1"), artistScore: 20, rank: 0),
                TasteCandidate(song: song(title: "OnGenre", artist: "B", isrc: "I2", genres: ["Hip-Hop"]), artistScore: 5, rank: 0)
            ],
            seeds: seeds
        )
        XCTAssertEqual(outranked.first?.song.title, "Strong")
    }

    func testDuplicateRecordingsAreCollapsed() {
        let seeds = buildTasteSeeds(library: [library("x", artist: "Me")], recents: [], spotlights: [])
        let picked = selectTasteTracks(
            candidates: [
                TasteCandidate(song: song(title: "Same", artist: "A", isrc: "DUP"), artistScore: 5, rank: 0),
                TasteCandidate(song: song(title: "Same", artist: "A", isrc: "DUP"), artistScore: 3, rank: 1)
            ],
            seeds: seeds
        )
        XCTAssertEqual(picked.count, 1)
    }

    /// Regenerating with unchanged inputs must not churn the user's list.
    func testSelectionIsDeterministic() {
        let seeds = buildTasteSeeds(library: [library("x", artist: "Me")], recents: [], spotlights: [])
        let candidates = (0..<12).map {
            TasteCandidate(song: song(title: "T\($0)", artist: "A\($0 % 4)", isrc: "I\($0)"), artistScore: 5, rank: 0)
        }
        let first = selectTasteTracks(candidates: candidates, seeds: seeds)
        let second = selectTasteTracks(candidates: candidates.reversed(), seeds: seeds)
        XCTAssertEqual(first.map(\.song.isrc), second.map(\.song.isrc))
    }

    func testLimitIsRespected() {
        let seeds = buildTasteSeeds(library: [library("x", artist: "Me")], recents: [], spotlights: [])
        let candidates = (0..<50).map {
            TasteCandidate(song: song(title: "T\($0)", artist: "A\($0)", isrc: "I\($0)"), artistScore: 5, rank: 0)
        }
        XCTAssertEqual(selectTasteTracks(candidates: candidates, seeds: seeds, limit: 25).count, 25)
    }

    // MARK: - Genre scoping judges the artist, not one track

    private func tagged(_ artist: String, _ n: Int, genres: [String], prefix: String) -> [TasteCandidate] {
        (0..<n).map {
            TasteCandidate(song: song(title: "\(prefix)\($0)", artist: artist, isrc: "\(prefix)\($0)", genres: genres),
                           artistScore: 5, rank: 5)
        }
    }

    /// Measured on a real device cache: Frank Ocean's "Novacane" / "Swim Good"
    /// carry a `Rock` tag (2 of 26 tracks). That alone must not admit him.
    func testOneMislabelledTrackDoesNotAdmitAnArtistToAGenre() {
        let rapper = tagged("Frank Ocean", 24, genres: ["Pop"], prefix: "F")
            + tagged("Frank Ocean", 2, genres: ["Alternative", "Rock", "R&B/Soul"], prefix: "FR")
        let band = tagged("Pink Floyd", 10, genres: ["Rock"], prefix: "P")
        let kept = filterCandidates(rapper + band, toGenre: "Rock")
        XCTAssertEqual(Set(kept.map(\.artistKey)), ["pink floyd"])
    }

    func testAnArtistWhoseMostCommonTagIsTheGenreAlwaysQualifies() {
        // 2 of 10 is under the share threshold, but it's their top tag.
        let c = tagged("Odd Band", 2, genres: ["Rock"], prefix: "R")
            + tagged("Odd Band", 8, genres: ["Alternative", "Pop"], prefix: "A")
        // "Alternative" and "Pop" (8 each) beat Rock (2): does NOT qualify.
        XCTAssertTrue(filterCandidates(c, toGenre: "Rock").isEmpty)
        let c2 = tagged("Small Band", 2, genres: ["Rock"], prefix: "S") + tagged("Small Band", 1, genres: ["Pop"], prefix: "T")
        XCTAssertEqual(filterCandidates(c2, toGenre: "Rock").count, 2)
    }

    func testGenreRunDoesNotSeedFromArtistWithOneStrayTaggedTrack() {
        let lib = (0..<20).map { library("r\($0)", artist: "Rapper", genres: ["Hip-Hop/Rap"]) }
            + [library("rx", artist: "Rapper", genres: ["Rock"])]
            + (0..<4).map { library("b\($0)", artist: "Rock Band", genres: ["Rock"]) }
        let seeds = buildTasteSeeds(library: lib, recents: [], spotlights: [], seedGenre: "Rock")
        XCTAssertEqual(seeds.artists.map(\.displayName), ["Rock Band"])
        XCTAssertTrue(seeds.knownArtistKeys.contains("rapper"), "still excluded as already-known")
    }
}
