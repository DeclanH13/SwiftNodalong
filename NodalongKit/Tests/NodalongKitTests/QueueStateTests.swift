import XCTest
@testable import NodalongKit

final class QueueStateTests: XCTestCase {
    private func song(_ title: String) -> Song {
        Song(id: title, title: title, artist: "A", album: "Al", artwork: "", trackId: title, uri: title)
    }
    /// A queue of `titles`, current at `at`.
    private func queue(_ titles: [String], at: Int = 0) -> QueueState {
        var s = QueueState()
        reduceQueue(&s, .replace(titles.map(song), startAt: at))
        return s
    }
    private func titles(_ s: QueueState) -> [String] { s.items.map(\.song.title) }
    private func upNext(_ s: QueueState) -> [String] { s.upNext.map(\.song.title) }
    private func id(_ s: QueueState, _ title: String) -> UUID { s.items.first { $0.song.title == title }!.id }

    // MARK: replace

    func testReplaceLoadsTheTappedTrack() {
        var s = QueueState()
        let effect = reduceQueue(&s, .replace([song("A"), song("B"), song("C")], startAt: 1))
        XCTAssertEqual(s.current?.song.title, "B")
        XCTAssertEqual(effect, .load(s.currentID!))
        XCTAssertEqual(upNext(s), ["C"])
        XCTAssertEqual(s.history.map(\.song.title), ["A"])
    }
    func testReplaceWithABadIndexIsIgnored() {
        var s = queue(["A", "B"])
        let before = s
        XCTAssertEqual(reduceQueue(&s, .replace([song("X")], startAt: 3)), .none)
        XCTAssertEqual(s, before)
    }
    func testReplaceDiscardsTheOldQueue() {
        var s = queue(["A", "B", "C"], at: 2)
        reduceQueue(&s, .replace([song("X")], startAt: 0))
        XCTAssertEqual(titles(s), ["X"])
    }

    // MARK: append / insert next

    func testAppendGoesToTheEndAndDoesNotInterrupt() {
        var s = queue(["A", "B"])
        let effect = reduceQueue(&s, .append(song("C"), startIfIdle: false))
        XCTAssertEqual(titles(s), ["A", "B", "C"])
        XCTAssertEqual(s.current?.song.title, "A")
        XCTAssertEqual(effect, .none)
    }
    func testAppendToAnEmptyQueueStartsIt() {
        var s = QueueState()
        let effect = reduceQueue(&s, .append(song("A"), startIfIdle: false))
        XCTAssertEqual(s.current?.song.title, "A")
        XCTAssertEqual(effect, .load(s.currentID!))
    }
    func testAppendAfterTheQueueFinishedStartsTheNewTrack() {
        var s = queue(["A", "B"], at: 1)
        let effect = reduceQueue(&s, .append(song("C"), startIfIdle: true))
        XCTAssertEqual(s.current?.song.title, "C")
        XCTAssertEqual(effect, .load(s.currentID!))
    }
    func testInsertNextGoesStraightAfterCurrent() {
        var s = queue(["A", "B", "C"])
        reduceQueue(&s, .insertNext(song("X"), startIfIdle: false))
        XCTAssertEqual(titles(s), ["A", "X", "B", "C"])
        XCTAssertEqual(s.current?.song.title, "A")
    }
    func testInsertNextWhenIdleStartsIt() {
        var s = queue(["A"])
        let effect = reduceQueue(&s, .insertNext(song("X"), startIfIdle: true))
        XCTAssertEqual(s.current?.song.title, "X")
        XCTAssertEqual(effect, .load(s.currentID!))
    }
    func testSameSongTwiceGetsTwoItems() {
        var s = queue(["A"])
        reduceQueue(&s, .append(song("B"), startIfIdle: false))
        reduceQueue(&s, .append(song("B"), startIfIdle: false))
        XCTAssertEqual(Set(s.items.map(\.id)).count, 3)
    }

    // MARK: move

    func testMoveToTop() {
        var s = queue(["X", "A", "B", "C"])
        reduceQueue(&s, .move(ids: [id(s, "C")], before: id(s, "A")))
        XCTAssertEqual(upNext(s), ["C", "A", "B"])
        XCTAssertEqual(s.current?.song.title, "X")
    }
    func testMoveToEnd() {
        var s = queue(["X", "A", "B", "C"])
        reduceQueue(&s, .move(ids: [id(s, "A")], before: nil))
        XCTAssertEqual(upNext(s), ["B", "C", "A"])
    }
    func testMoveSeveralKeepsTheirOrder() {
        var s = queue(["X", "A", "B", "C", "D"])
        reduceQueue(&s, .move(ids: [id(s, "D"), id(s, "B")], before: id(s, "A")))
        XCTAssertEqual(upNext(s), ["B", "D", "A", "C"])
    }
    func testMoveBeforeOneOfItsOwnMembersAnchorsOnTheNextOther() {
        var s = queue(["X", "A", "B", "C", "D"])
        reduceQueue(&s, .move(ids: [id(s, "A"), id(s, "B")], before: id(s, "B")))
        XCTAssertEqual(upNext(s), ["A", "B", "C", "D"])
    }
    /// The B6 fix: an edit made against an older view of Up Next can only touch
    /// the items it named. Here the queue advanced past A before the drop landed.
    func testMoveAfterTheQueueAdvancedOnlyTouchesTheNamedItems() {
        var s = queue(["X", "A", "B", "C"])
        let a = id(s, "A"), c = id(s, "C")
        reduceQueue(&s, .next)                                   // now on A
        reduceQueue(&s, .move(ids: [c], before: id(s, "B")))
        XCTAssertEqual(s.current?.id, a)
        XCTAssertEqual(upNext(s), ["C", "B"])
    }
    func testMovingTheCurrentOrAVanishedItemIsANoOp() {
        var s = queue(["X", "A", "B"])
        let before = s
        XCTAssertEqual(reduceQueue(&s, .move(ids: [s.currentID!], before: nil)), .none)
        XCTAssertEqual(reduceQueue(&s, .move(ids: [UUID()], before: nil)), .none)
        XCTAssertEqual(s, before)
    }
    func testMoveToTheSamePlaceDoesNotBumpTheEpoch() {
        var s = queue(["X", "A", "B"])
        let epoch = s.epoch
        reduceQueue(&s, .move(ids: [id(s, "A")], before: id(s, "B")))
        XCTAssertEqual(s.epoch, epoch)
    }

    // MARK: remove / clear

    func testRemoveTakesOnlyUpNextItems() {
        var s = queue(["X", "A", "B"])
        reduceQueue(&s, .remove(ids: [id(s, "A"), s.currentID!]))
        XCTAssertEqual(titles(s), ["X", "B"])
    }
    func testRemoveAfterTheQueueAdvancedRemovesTheNamedItem() {
        var s = queue(["X", "A", "B", "C"])
        let b = id(s, "B")
        reduceQueue(&s, .next)
        reduceQueue(&s, .remove(ids: [b]))
        XCTAssertEqual(upNext(s), ["C"])
    }
    func testClearUpNextKeepsHistoryAndCurrent() {
        var s = queue(["H", "X", "A", "B"], at: 1)
        let effect = reduceQueue(&s, .clearUpNext)
        XCTAssertEqual(titles(s), ["H", "X"])
        XCTAssertEqual(s.current?.song.title, "X")
        XCTAssertEqual(effect, .none)
    }

    // MARK: next / previous / jump

    func testNextLoadsTheNextTrack() {
        var s = queue(["A", "B"])
        let effect = reduceQueue(&s, .next)
        XCTAssertEqual(s.current?.song.title, "B")
        XCTAssertEqual(effect, .load(s.currentID!))
    }
    func testNextAtTheEndStopsAndKeepsTheTrack() {
        var s = queue(["A", "B"], at: 1)
        XCTAssertEqual(reduceQueue(&s, .next), .stop)
        XCTAssertEqual(s.current?.song.title, "B")
    }
    func testPreviousStepsBack() {
        var s = queue(["A", "B"], at: 1)
        let effect = reduceQueue(&s, .previous(restartInstead: false))
        XCTAssertEqual(s.current?.song.title, "A")
        XCTAssertEqual(effect, .load(s.currentID!))
    }
    func testPreviousRestartsWhenAskedOrWithNoHistory() {
        var s = queue(["A", "B"], at: 1)
        XCTAssertEqual(reduceQueue(&s, .previous(restartInstead: true)), .restart)
        XCTAssertEqual(s.current?.song.title, "B")
        var t = queue(["A", "B"])
        XCTAssertEqual(reduceQueue(&t, .previous(restartInstead: false)), .restart)
    }
    func testJump() {
        var s = queue(["A", "B", "C"])
        let c = id(s, "C")
        XCTAssertEqual(reduceQueue(&s, .jump(c)), .load(c))
        XCTAssertEqual(s.current?.id, c)
        XCTAssertEqual(reduceQueue(&s, .jump(UUID())), .none)
    }

    // MARK: track end / unplayable

    func testTrackEndedAdvances() {
        var s = queue(["A", "B"])
        let a = s.currentID!
        XCTAssertEqual(reduceQueue(&s, .trackEnded(itemID: a)), .load(id(s, "B")))
    }
    /// The B5 fix: an end-of-track confirmation that lands after a skip already
    /// moved on must not advance a second time.
    func testTrackEndedForANonCurrentItemIsIgnored() {
        var s = queue(["A", "B", "C"])
        let a = s.currentID!
        reduceQueue(&s, .next)
        XCTAssertEqual(reduceQueue(&s, .trackEnded(itemID: a)), .none)
        XCTAssertEqual(s.current?.song.title, "B")
    }
    func testTrackEndedOnTheLastTrackStops() {
        var s = queue(["A"])
        XCTAssertEqual(reduceQueue(&s, .trackEnded(itemID: s.currentID!)), .stop)
    }
    func testSkipUnplayableOnlyIfStillCurrent() {
        var s = queue(["A", "B", "C"])
        let a = s.currentID!
        XCTAssertEqual(reduceQueue(&s, .skipUnplayable(itemID: a)), .load(id(s, "B")))
        XCTAssertEqual(reduceQueue(&s, .skipUnplayable(itemID: a)), .none)
    }

    // MARK: native moves

    func testNativeMoveToAnItemIsAdoptedWithoutReload() {
        var s = queue(["A", "B", "C"])
        let c = id(s, "C")
        XCTAssertEqual(reduceQueue(&s, .nativeMoved(toItemID: c)), .adopt(c))
        XCTAssertEqual(s.current?.id, c)
    }
    func testNativeMoveBackwardIsAdopted() {
        var s = queue(["A", "B"], at: 1)
        let a = id(s, "A")
        XCTAssertEqual(reduceQueue(&s, .nativeMoved(toItemID: a)), .adopt(a))
    }
    func testNativeMoveOntoTheCurrentItemIsANoOp() {
        var s = queue(["A", "B"])
        let epoch = s.epoch
        XCTAssertEqual(reduceQueue(&s, .nativeMoved(toItemID: s.currentID!)), .none)
        XCTAssertEqual(s.epoch, epoch)
    }
    /// The B3 fix: MusicKit started a track we cleared. Play what we want next…
    func testNativeMoveOntoAGhostLoadsWhatWeWantNext() {
        var s = queue(["X", "A", "B"])
        let a = id(s, "A")
        XCTAssertEqual(reduceQueue(&s, .nativeMoved(toItemID: nil)), .load(a))
        XCTAssertEqual(s.current?.id, a)
    }
    /// …or stop, instead of letting the cleared track play on under the old title.
    func testNativeMoveOntoAGhostWithNothingQueuedStops() {
        var s = queue(["X", "A"])
        reduceQueue(&s, .clearUpNext)
        XCTAssertEqual(reduceQueue(&s, .nativeMoved(toItemID: nil)), .stop)
        XCTAssertEqual(reduceQueue(&s, .nativeMoved(toItemID: UUID())), .stop)
    }

    // MARK: party reconcile

    func testReconcileKeepsHistorySoPreviousStillWorks() {
        var s = queue(["H", "X", "A"], at: 1)
        let h = id(s, "H")
        reduceQueue(&s, .reconcile([song("H"), song("X"), song("B"), song("A")]))
        XCTAssertEqual(titles(s), ["H", "X", "B", "A"])
        XCTAssertEqual(s.current?.song.title, "X")
        XCTAssertEqual(s.history.first?.id, h)        // B7: history kept, same item
    }
    func testReconcileReusesExistingItems() {
        var s = queue(["X", "A", "B"])
        let a = id(s, "A")
        reduceQueue(&s, .reconcile([song("X"), song("B"), song("A")]))
        XCTAssertEqual(id(s, "A"), a)
    }
    func testReconcileWithTheSameOrderIsANoOp() {
        var s = queue(["X", "A"])
        let before = s
        XCTAssertEqual(reduceQueue(&s, .reconcile([song("X"), song("A")])), .none)
        XCTAssertEqual(s, before)
    }
    func testReconcileWithoutTheCurrentTrackIsIgnored() {
        var s = queue(["X", "A"])
        let before = s
        reduceQueue(&s, .reconcile([song("Y"), song("Z")]))
        XCTAssertEqual(s, before)
    }
    func testReconcileWithADuplicatedSongKeepsBothCopies() {
        var s = queue(["X"])
        reduceQueue(&s, .reconcile([song("X"), song("A"), song("A")]))
        XCTAssertEqual(upNext(s), ["A", "A"])
        XCTAssertEqual(Set(s.upNext.map(\.id)).count, 2)
    }

    // MARK: epoch / restore / clear all

    func testEpochBumpsOnlyOnRealChanges() {
        var s = queue(["X", "A", "B"])
        var last = s.epoch
        func changed(_ c: QueueCommand) -> Bool {
            reduceQueue(&s, c)
            defer { last = s.epoch }
            return s.epoch != last
        }
        XCTAssertTrue(changed(.append(song("C"), startIfIdle: false)))
        XCTAssertTrue(changed(.move(ids: [id(s, "C")], before: id(s, "A"))))
        XCTAssertTrue(changed(.next))
        XCTAssertFalse(changed(.remove(ids: [UUID()])))
        XCTAssertFalse(changed(.jump(UUID())))
        XCTAssertFalse(changed(.trackEnded(itemID: UUID())))
        XCTAssertFalse(changed(.previous(restartInstead: true)))
    }
    func testRestoreClampsTheIndex() {
        let items = ["A", "B"].map { QueueItem(song: song($0)) }
        XCTAssertEqual(QueueState(items: items, currentIndex: 9).current?.song.title, "B")
        XCTAssertEqual(QueueState(items: items, currentIndex: -1).current?.song.title, "A")
        XCTAssertNil(QueueState(items: [], currentIndex: 0).currentID)
    }
    func testRestoreRoundTripsThroughCodable() throws {
        let s = queue(["A", "B", "C"], at: 1)
        let decoded = try JSONDecoder().decode(QueueState.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(decoded, s)
    }
    func testClearAll() {
        var s = queue(["A", "B"])
        reduceQueue(&s, .clearAll)
        XCTAssertTrue(s.items.isEmpty)
        XCTAssertNil(s.currentID)
        XCTAssertFalse(s.hasNext)
    }
}
