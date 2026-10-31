import XCTest
@testable import NodalongKit

final class InboxItemTests: XCTestCase {
    func testParsesSongItem() {
        let item = InboxItem(id: "a", data: ["type": "song", "fromUid": "u1", "fromUsername": "sam",
                                             "catalogId": "c1", "note": "listen", "createdAt": 5.0])
        XCTAssertEqual(item?.kind, .song)
        XCTAssertEqual(item?.note, "listen")
        XCTAssertEqual(item?.catalogId, "c1")
    }

    func testUnknownTypeIsTolerated() {
        let item = InboxItem(id: "a", data: ["type": "future-thing", "fromUid": "u1", "createdAt": 1.0])
        XCTAssertEqual(item?.kind, .unknown)
    }

    func testMissingSenderIsRejected() {
        XCTAssertNil(InboxItem(id: "a", data: ["type": "song"]))
    }

    func testUnreadCountUsesWatermarkAndSkipsUnknown() {
        let items = [
            InboxItem(id: "1", kind: .song, fromUid: "u", fromUsername: "u", createdAt: 10),
            InboxItem(id: "2", kind: .song, fromUid: "u", fromUsername: "u", createdAt: 3),
            InboxItem(id: "3", kind: .unknown, fromUid: "u", fromUsername: "u", createdAt: 20),
        ]
        XCTAssertEqual(unreadInboxCount(items: items, seenAtMs: 5), 1)
        XCTAssertEqual(unreadInboxCount(items: items, seenAtMs: 0), 2)
    }
}
