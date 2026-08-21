import XCTest
@testable import NodalongKit

final class NodalongKitTests: XCTestCase {
    func testMusicServiceTypeRawValues() {
        XCTAssertEqual(MusicServiceType.spotify.rawValue, "spotify")
        XCTAssertEqual(MusicServiceType.appleMusic.rawValue, "apple_music")
    }
}
