import XCTest
@testable import NodalongKit

final class GenreNormalizationTests: XCTestCase {

    /// Apple puts "Music" on nearly everything; left in, it becomes the biggest
    /// bucket in any grouping while telling the user nothing.
    func testDropsUmbrellaGenres() {
        XCTAssertEqual(normalizedGenres(["Alternative", "Music"]), ["Alternative"])
        XCTAssertEqual(normalizedGenres(["Music"]), [])
    }

    func testDropsUmbrellaGenresCaseInsensitively() {
        XCTAssertEqual(normalizedGenres(["Rock", "MUSIC", "music"]), ["Rock"])
    }

    func testPreservesSourceOrderingMostSpecificFirst() {
        XCTAssertEqual(normalizedGenres(["Hip-Hop/Rap", "Rap", "Music"]), ["Hip-Hop/Rap", "Rap"])
    }

    func testDedupesCaseInsensitivelyKeepingFirstCasing() {
        XCTAssertEqual(normalizedGenres(["Rock", "rock", "ROCK"]), ["Rock"])
    }

    func testTrimsWhitespaceAndDropsBlanks() {
        XCTAssertEqual(normalizedGenres(["  Jazz  ", "", "   "]), ["Jazz"])
    }

    func testEmptyInputYieldsEmpty() {
        XCTAssertTrue(normalizedGenres([]).isEmpty)
    }
}
