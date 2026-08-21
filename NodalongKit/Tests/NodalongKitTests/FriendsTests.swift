import XCTest
@testable import NodalongKit

final class FriendsTests: XCTestCase {

    func testMutualOnly() {
        let following = ["a", "b", "c", "d"]
        let followers = ["b", "d", "e"]
        XCTAssertEqual(friendUids(following: following, followers: followers), ["b", "d"])
    }

    func testPreservesFollowingOrder() {
        let following = ["c", "a", "b"]
        let followers = ["a", "b", "c"]
        XCTAssertEqual(friendUids(following: following, followers: followers), ["c", "a", "b"])
    }

    func testNoOverlap() {
        XCTAssertEqual(friendUids(following: ["a"], followers: ["b"]), [])
    }

    func testEmptyInputs() {
        XCTAssertEqual(friendUids(following: [], followers: ["a"]), [])
        XCTAssertEqual(friendUids(following: ["a"], followers: []), [])
    }

    func testDeduplicatesFollowing() {
        // A malformed following list with a dupe shouldn't yield a duplicate friend.
        XCTAssertEqual(friendUids(following: ["a", "a", "b"], followers: ["a", "b"]), ["a", "b"])
    }
}
