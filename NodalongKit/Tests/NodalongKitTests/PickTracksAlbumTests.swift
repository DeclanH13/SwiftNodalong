import XCTest
@testable import NodalongKit

final class PickTracksAlbumTests: XCTestCase {
    private func cand(_ title: String, album: String, rank: Int) -> TasteCandidate {
        let s = Song(id: title, title: title, artist: "A", album: album, artwork: "", trackId: title,
                     uri: "u", sourceService: .appleMusic, isrc: title)
        return TasteCandidate(song: s, artistScore: 1, rank: rank)
    }
    func testSecondSlotPrefersADifferentAlbum() {
        let t = [cand("1", album: "X", rank: 0), cand("2", album: "X", rank: 1), cand("3", album: "Y", rank: 2)]
        XCTAssertEqual(pickTracks(from: t, count: 2).map(\.song.title), ["1", "3"])
    }
    func testFallsBackWhenAllSameAlbum() {
        let t = [cand("1", album: "X", rank: 0), cand("2", album: "X", rank: 1)]
        XCTAssertEqual(pickTracks(from: t, count: 2).map(\.song.title), ["1", "2"])
    }
    func testSingleSlotIsJustTheBest() {
        let t = [cand("1", album: "X", rank: 0), cand("2", album: "Y", rank: 1)]
        XCTAssertEqual(pickTracks(from: t, count: 1).map(\.song.title), ["1"])
    }
}
