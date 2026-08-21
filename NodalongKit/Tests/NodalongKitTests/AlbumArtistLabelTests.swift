import XCTest
@testable import NodalongKit

final class AlbumArtistLabelTests: XCTestCase {

    func testReturnsDefaultLabelWhenAllPrimaryArtistsAgree() {
        let label = albumArtistLabel(defaultLabel: "Jamie xx", trackArtists: ["Jamie xx", "Jamie xx & Honey Dijon"])
        XCTAssertEqual(label, "Jamie xx")
    }

    func testReturnsVariousArtistsWhenPrimariesGenuinelyDiffer() {
        let label = albumArtistLabel(defaultLabel: "Artist A", trackArtists: ["Artist A", "Artist B", "Artist C"])
        XCTAssertEqual(label, variousArtistsLabel)
    }

    func testSingleTrackReturnsDefaultLabel() {
        let label = albumArtistLabel(defaultLabel: "Solo Artist", trackArtists: ["Solo Artist"])
        XCTAssertEqual(label, "Solo Artist")
    }

    func testCaseInsensitiveComparisonStillAgrees() {
        let label = albumArtistLabel(defaultLabel: "Artist X", trackArtists: ["Artist X", "ARTIST X", "artist x"])
        XCTAssertEqual(label, "Artist X")
    }
}
