import XCTest
@testable import NodalongKit

final class ReleaseMatchingTests: XCTestCase {

    // --- containsCompilationKeyword ---

    func testContainsCompilationKeywordDetectsGreatestHits() {
        XCTAssertTrue(containsCompilationKeyword("Greatest Hits"))
    }

    func testContainsCompilationKeywordDetectsDeluxe() {
        XCTAssertTrue(containsCompilationKeyword("Late Registration (Deluxe Edition)"))
    }

    func testContainsCompilationKeywordCaseInsensitive() {
        XCTAssertTrue(containsCompilationKeyword("THE BEST OF COLDPLAY"))
    }

    func testContainsCompilationKeywordFalseForStudioAlbum() {
        XCTAssertFalse(containsCompilationKeyword("Late Registration"))
    }

    // --- bestReleaseIndex ---

    func testBestReleaseIndexEmptyReturnsNil() {
        XCTAssertNil(bestReleaseIndex(albumNames: [], expectedAlbum: nil))
    }

    func testBestReleaseIndexSingleCandidate() {
        XCTAssertEqual(bestReleaseIndex(albumNames: ["Late Registration"], expectedAlbum: nil), 0)
    }

    func testBestReleaseIndexExactAlbumMatchWinsOverCompilation() {
        let albums = ["Greatest Hits", "Late Registration"]
        XCTAssertEqual(bestReleaseIndex(albumNames: albums, expectedAlbum: "Late Registration"), 1)
    }

    func testBestReleaseIndexSubstringMatchWins() {
        let albums = ["Greatest Hits", "Late Registration (Deluxe Edition)"]
        // "Late Registration" is contained in the deluxe candidate's name —
        // still a meaningful signal even though it's not an exact match.
        XCTAssertEqual(bestReleaseIndex(albumNames: albums, expectedAlbum: "Late Registration"), 1)
    }

    func testBestReleaseIndexKeywordPenaltyWithNoExpectedAlbum() {
        let albums = ["Greatest Hits", "Late Registration"]
        XCTAssertEqual(bestReleaseIndex(albumNames: albums, expectedAlbum: nil), 1)
    }

    func testBestReleaseIndexTiesKeepFirstResult() {
        let albums = ["Album A", "Album B", "Album C"]
        XCTAssertEqual(bestReleaseIndex(albumNames: albums, expectedAlbum: nil), 0)
    }

    func testBestReleaseIndexAllCompilationsStillPicksFirst() {
        // No clean option exists — falls back to today's "first result" behavior.
        let albums = ["Greatest Hits", "Deluxe Edition Reissue"]
        XCTAssertEqual(bestReleaseIndex(albumNames: albums, expectedAlbum: nil), 0)
    }

    // --- isBetterRelease ---

    func testIsBetterReleaseTrueWhenExistingIsCompilation() {
        XCTAssertTrue(isBetterRelease(newAlbum: "Late Registration", existingAlbum: "Greatest Hits"))
    }

    func testIsBetterReleaseFalseWhenBothClean() {
        XCTAssertFalse(isBetterRelease(newAlbum: "Late Registration", existingAlbum: "Late Registration"))
    }

    func testIsBetterReleaseFalseWhenNewIsAlsoCompilation() {
        XCTAssertFalse(isBetterRelease(newAlbum: "Best Of", existingAlbum: "Greatest Hits"))
    }

    func testIsBetterReleaseFalseWhenExistingIsAlreadyClean() {
        // One-directional: never downgrades an already-good match.
        XCTAssertFalse(isBetterRelease(newAlbum: "Greatest Hits", existingAlbum: "Late Registration"))
    }

    // --- albumNamesMatch ---

    func testAlbumNamesMatchExact() {
        XCTAssertTrue(albumNamesMatch("Since I Left You", "since i left you"))
    }

    func testAlbumNamesMatchStoreSuffix() {
        // A " - Single" store suffix on one side must not break the match.
        XCTAssertTrue(albumNamesMatch(
            "Every Single Weekend (feat. Jamie xx) - Single",
            "Every Single Weekend (feat. Jamie xx)"
        ))
    }

    func testAlbumNamesMatchRejectsDifferentRelease() {
        // The pre-release-single failure mode: the parent album is NOT the
        // release the user tapped, no matter how the candidates were ranked.
        XCTAssertFalse(albumNamesMatch(
            "No Bad Memories",
            "Every Single Weekend (feat. Jamie xx)"
        ))
    }

    func testAlbumNamesMatchRejectsEmpty() {
        XCTAssertFalse(albumNamesMatch("", "Since I Left You"))
        XCTAssertFalse(albumNamesMatch("Since I Left You", ""))
    }

    // --- albumNamesExactMatch ---

    func testAlbumNamesExactMatchAcceptsCaseInsensitiveExact() {
        XCTAssertTrue(albumNamesExactMatch("Since I Left You", "since i left you"))
    }

    func testAlbumNamesExactMatchRejectsSingleEditionOfTheSameAlbum() {
        // The actual bug this exists to fix: a recording's own release can
        // be a promotional single/feat. edit sharing the parent album's
        // base name — `albumNamesMatch`'s containment leniency accepts it,
        // but it is NOT the full album the user is trying to open.
        XCTAssertFalse(albumNamesExactMatch(
            "We Will Always Love You (feat. Blood Orange) - Single",
            "We Will Always Love You"
        ))
    }

    func testAlbumNamesExactMatchRejectsEmpty() {
        XCTAssertFalse(albumNamesExactMatch("", "Since I Left You"))
        XCTAssertFalse(albumNamesExactMatch("Since I Left You", ""))
    }
}

// MARK: - Single-vs-album upgrade (the "Salt of the Lee" bug)
//
// A recording released as a standalone single AND on an EP shares one ISRC,
// so it shares one catalog row. Whichever release was ingested first owns
// the album name — and if that was the single, Shelf's `groupByAlbum` (which
// keys on album name) strands the track as its own one-track tile instead of
// grouping it under the EP.

final class SingleLikeAlbumTests: XCTestCase {

    func testExplicitSingleSuffixIsSingleLike() {
        XCTAssertTrue(isSingleLikeAlbum(album: "Dungarvan Bay - Single", trackTitle: "Dungarvan Bay"))
        // …even when the title doesn't match, the suffix alone is decisive.
        XCTAssertTrue(isSingleLikeAlbum(album: "Some Other Name - Single", trackTitle: "Dungarvan Bay"))
    }

    // A bare album name matching the track title is NOT treated as a single —
    // title tracks are far too common, and this feeds an OVERWRITE decision.
    // Real examples caught on device: "This Is Why" (Paramore), "Visions of a
    // Life" (Wolf Alice), "3D Country" (Geese) — all genuine albums.
    func testAlbumNameEqualToTrackTitleIsNotSingleLike() {
        XCTAssertFalse(isSingleLikeAlbum(album: "Dungarvan Bay", trackTitle: "Dungarvan Bay"))
        XCTAssertFalse(isSingleLikeAlbum(album: "This Is Why", trackTitle: "This Is Why"))
        XCTAssertFalse(isSingleLikeAlbum(album: "3D Country", trackTitle: "3D Country"))
    }

    // The corollary that actually matters: a title-track album must never be
    // overwritten by some other release just because its name matches.
    func testTitleTrackAlbumIsNeverOverwritten() {
        XCTAssertFalse(isBetterRelease(
            newAlbum: "Some Compilation",
            existingAlbum: "This Is Why",
            trackTitle: "This Is Why"
        ))
    }

    func testRealAlbumIsNotSingleLike() {
        XCTAssertFalse(isSingleLikeAlbum(album: "Salt of the Lee", trackTitle: "Dungarvan Bay"))
        XCTAssertFalse(isSingleLikeAlbum(album: "Salt of the Lee - EP", trackTitle: "Dungarvan Bay"))
    }

    func testEmptyInputsAreNotSingleLike() {
        XCTAssertFalse(isSingleLikeAlbum(album: "", trackTitle: "Dungarvan Bay"))
        XCTAssertFalse(isSingleLikeAlbum(album: "Salt of the Lee", trackTitle: ""))
    }

    // The actual reported case: the EP must win over the single.
    func testAlbumUpgradesOverSingle() {
        XCTAssertTrue(isBetterRelease(
            newAlbum: "Salt of the Lee",
            existingAlbum: "Dungarvan Bay - Single",
            trackTitle: "Dungarvan Bay"
        ))
        // Note the existing side must carry the explicit "- Single" suffix;
        // a bare "Dungarvan Bay" is indistinguishable from a title track.
        XCTAssertTrue(isBetterRelease(
            newAlbum: "Salt of the Lee - EP",
            existingAlbum: "Dungarvan Bay - Single",
            trackTitle: "Dungarvan Bay"
        ))
    }

    // One-directional: a good row must never be regressed back to the single.
    func testSingleDoesNotOverwriteAlbum() {
        XCTAssertFalse(isBetterRelease(
            newAlbum: "Dungarvan Bay - Single",
            existingAlbum: "Salt of the Lee",
            trackTitle: "Dungarvan Bay"
        ))
    }

    func testEmptyNewAlbumNeverWins() {
        XCTAssertFalse(isBetterRelease(
            newAlbum: "",
            existingAlbum: "Dungarvan Bay - Single",
            trackTitle: "Dungarvan Bay"
        ))
        XCTAssertFalse(isBetterRelease(
            newAlbum: "   ",
            existingAlbum: "Dungarvan Bay - Single",
            trackTitle: "Dungarvan Bay"
        ))
    }

    func testTwoRealAlbumsDoNotTriggerAnUpgrade() {
        XCTAssertFalse(isBetterRelease(
            newAlbum: "Salt of the Lee",
            existingAlbum: "Some Other Album",
            trackTitle: "Dungarvan Bay"
        ))
    }

    // The pre-existing compilation behaviour must be unchanged, including
    // when `trackTitle` isn't supplied at all (default argument).
    func testCompilationUpgradeStillWorksWithoutTrackTitle() {
        XCTAssertTrue(isBetterRelease(newAlbum: "Blonde", existingAlbum: "Greatest Hits"))
        XCTAssertFalse(isBetterRelease(newAlbum: "Greatest Hits", existingAlbum: "Blonde"))
    }
}
