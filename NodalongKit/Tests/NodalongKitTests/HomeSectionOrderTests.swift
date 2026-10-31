import XCTest
@testable import NodalongKit

final class HomeSectionOrderTests: XCTestCase {

    private let all = HomeSectionID.allCases

    // MARK: - Base ordering

    func testBaseRankOrdersWhenNothingIsFresh() {
        let result = orderHomeSections(available: all)
        XCTAssertEqual(result, all.sorted { $0.baseRank < $1.baseRank })
    }

    func testPeopleDrivenSectionsOutrankAppleShelvesByDefault() {
        let result = orderHomeSections(available: all)
        let spotlights = result.firstIndex(of: .friendsSpotlights)!
        for appleSection in [HomeSectionID.cityCharts, .recommended] {
            XCTAssertLessThan(
                spotlights, result.firstIndex(of: appleSection)!,
                "\(appleSection) should sit below friends' spotlights by default"
            )
        }
    }

    func testEveryBaseRankIsDistinct() {
        // Two sections sharing a rank makes `sorted` non-deterministic, which
        // would silently break the stability property below.
        XCTAssertEqual(Set(all.map(\.baseRank)).count, all.count)
    }

    // MARK: - Freshness

    func testFreshSectionFloatsAboveEveryNonFreshSection() {
        let result = orderHomeSections(available: all, fresh: [.recommended])
        XCTAssertEqual(result.first, .recommended)
    }

    func testBaseRankStillHoldsAmongFreshSections() {
        let result = orderHomeSections(available: all, fresh: [.recommended, .mostNodded])
        XCTAssertEqual(Array(result.prefix(2)), [.mostNodded, .recommended])
    }

    func testFreshnessForAnUnavailableSectionIsIgnored() {
        let result = orderHomeSections(available: [.jumpBackIn, .recommended], fresh: [.liveNow])
        XCTAssertEqual(result, [.jumpBackIn, .recommended])
    }

    // MARK: - Stability

    /// The property this whole two-bucket design exists to protect: Home does
    /// not rearrange itself when nothing has actually changed.
    func testIdenticalInputsProduceIdenticalOrder() {
        let a = orderHomeSections(available: all, fresh: [.liveNow, .newReleases], pinned: [.mostNodded])
        let b = orderHomeSections(available: all, fresh: [.liveNow, .newReleases], pinned: [.mostNodded])
        XCTAssertEqual(a, b)
        XCTAssertEqual(a, orderHomeSections(available: all.reversed(), fresh: [.liveNow, .newReleases], pinned: [.mostNodded]),
                       "input order must not leak into the result")
    }

    // MARK: - Pinning

    func testPinOutranksFreshness() {
        let result = orderHomeSections(available: all, fresh: [.liveNow], pinned: [.recentlyAdded])
        XCTAssertEqual(result.first, .recentlyAdded)
        XCTAssertEqual(result[1], .liveNow)
    }

    func testPinsKeepTheOrderTheUserChose() {
        let result = orderHomeSections(available: all, pinned: [.recommended, .cityCharts])
        XCTAssertEqual(Array(result.prefix(2)), [.recommended, .cityCharts])
    }

    func testPinnedButUnavailableSectionIsSkipped() {
        let result = orderHomeSections(available: [.jumpBackIn, .recommended], pinned: [.liveNow, .recommended])
        XCTAssertEqual(result, [.recommended, .jumpBackIn])
    }

    func testDuplicatePinIsNotRenderedTwice() {
        let result = orderHomeSections(available: all, pinned: [.recommended, .recommended])
        XCTAssertEqual(result.filter { $0 == .recommended }.count, 1)
        XCTAssertEqual(result.count, all.count)
    }

    // MARK: - Hiding

    func testHiddenSectionIsDropped() {
        let result = orderHomeSections(available: all, hidden: [.recommended])
        XCTAssertFalse(result.contains(.recommended))
        XCTAssertEqual(result.count, all.count - 1)
    }

    func testJumpBackInSurvivesBeingHidden() {
        XCTAssertFalse(HomeSectionID.jumpBackIn.isHideable)
        let result = orderHomeSections(available: all, hidden: Set(all))
        XCTAssertEqual(result, [.jumpBackIn])
    }

    func testHiddenSectionCannotBeResurrectedByPinningIt() {
        let result = orderHomeSections(available: all, pinned: [.recommended], hidden: [.recommended])
        XCTAssertFalse(result.contains(.recommended))
    }

    // MARK: - See-all coverage

    func testSectionsWithNothingTruncatedOfferNoSeeAll() {
        for id in [HomeSectionID.madeByPeople, .foundForYou, .liveNow, .recommended] {
            XCTAssertFalse(id.hasSeeAll, "\(id) should not offer a see-all")
        }
        for id in [HomeSectionID.jumpBackIn, .newReleases, .friendsListening,
                   .mostNodded, .recentlyAdded, .cityCharts, .genreCharts] {
            XCTAssertTrue(id.hasSeeAll, "\(id) is capped and should offer a see-all")
        }
    }

    /// Retired with the sections they described, rather than deleted quietly:
    ///
    /// - `testPersonalChartsOutrankTheGlobalChart` pinned the city and genre
    ///   charts above the global Daily Top. There is no global chart any more
    ///   — for a storefront whose capital dominates its population it
    ///   overlapped `cityTop` almost entirely and nothing deduped them.
    /// - `testRecentlyPlayedSitsWithJumpBackIn` pinned Apple's
    ///   recently-played containers directly beneath Jump Back In because
    ///   "the two answer the same question". They answer it so nearly
    ///   identically that they are now ONE rail, so there is no adjacency
    ///   left to assert. That merge is a view-layer concern
    ///   (`HomeView.jumpBackInRail`) and not something this pure function
    ///   can see.
    ///
    /// What replaces the first is the property that actually matters now: a
    /// chart only leads when it has earned the fresh bucket.
    func testAChartOnlyOutranksPeopleContentWhenActuallyFresh() {
        let notFresh = orderHomeSections(available: [.cityCharts, .jumpBackIn])
        XCTAssertEqual(notFresh, [.jumpBackIn, .cityCharts],
                       "a chart that hasn't changed must not outrank your own listening")

        let fresh = orderHomeSections(available: [.cityCharts, .jumpBackIn], fresh: [.cityCharts])
        XCTAssertEqual(fresh, [.cityCharts, .jumpBackIn],
                       "a chart that genuinely turned over may lead")
    }
}
