import XCTest
@testable import NodalongKit

final class DiscoveryVarietyTests: XCTestCase {
    private func seeds(_ n: Int) -> [SeededArtist] {
        (0..<n).map { SeededArtist(key: "a\($0)", displayName: "A\($0)", weight: Double(n - $0)) }
    }

    func testNoSeedMeansPlainTopN() {
        XCTAssertEqual(rotatedSeeds(seeds(30), shuffleSeed: nil).map(\.key), (0..<8).map { "a\($0)" })
    }

    func testTopSeedsAlwaysStayAndRestComeFromThePool() {
        let r = rotatedSeeds(seeds(30), shuffleSeed: 42)
        XCTAssertEqual(r.count, 8)
        XCTAssertEqual(Set(r.prefix(4).map(\.key)), ["a0", "a1", "a2", "a3"])
        XCTAssertTrue(r.dropFirst(4).allSatisfy { Int($0.key.dropFirst())! >= 4 && Int($0.key.dropFirst())! < 25 })
    }

    func testRotationIsDeterministicPerSeedAndVariesAcrossSeeds() {
        XCTAssertEqual(rotatedSeeds(seeds(30), shuffleSeed: 1), rotatedSeeds(seeds(30), shuffleSeed: 1))
        let distinct = Set((1...12).map { rotatedSeeds(seeds(30), shuffleSeed: UInt64($0)).map(\.key) })
        XCTAssertGreaterThan(distinct.count, 3)
    }

    func testFewSeedsAreReturnedAsIs() {
        XCTAssertEqual(rotatedSeeds(seeds(5), shuffleSeed: 9).count, 5)
    }

    func testNoveltyRecoversOverTheWindow() {
        let day = 86_400.0, now = 100 * day
        let m = noveltyMultipliers(recent: ["fresh": now, "half": now - 14 * day, "old": now - 40 * day], nowSeconds: now)
        XCTAssertEqual(m["fresh"]!, noveltyFloor, accuracy: 1e-9)
        XCTAssertEqual(m["half"]!, noveltyFloor + (1 - noveltyFloor) * 0.5, accuracy: 1e-9)
        XCTAssertNil(m["old"])
    }

    private func similar(_ items: [(String, String)]) -> [(id: String, name: String)] { items.map { (id: $0.0, name: $0.1) } }

    func testHubDampeningLetsASingleStrongSeedBeatAHub() {
        let a = SeededArtist(key: "a", displayName: "A", weight: 1)
        let b = SeededArtist(key: "b", displayName: "B", weight: 1)
        let c = SeededArtist(key: "c", displayName: "C", weight: 1)
        let d = SeededArtist(key: "d", displayName: "D", weight: 1.4)
        let input: [(seed: SeededArtist, similar: [(id: String, name: String)])] = [
            (a, similar([("hub", "Hub")])), (b, similar([("hub", "Hub")])), (c, similar([("hub", "Hub")])),
            (d, similar([("niche", "Niche")])),
        ]
        XCTAssertEqual(rankCandidateArtists(similarBySeed: input, excluding: [], limit: 2).first?.name, "Hub")
        XCTAssertEqual(rankCandidateArtists(similarBySeed: input, excluding: [], limit: 2, dampenHubs: true).first?.name, "Niche")
    }

    func testNoveltyPushesARecentlySuggestedArtistDown() {
        let a = SeededArtist(key: "a", displayName: "A", weight: 1)
        let input: [(seed: SeededArtist, similar: [(id: String, name: String)])] = [(a, similar([("x", "Xavier"), ("y", "Yolanda")]))]
        let r = rankCandidateArtists(similarBySeed: input, excluding: [], limit: 2, novelty: ["xavier": 0.25])
        XCTAssertEqual(r.first?.name, "Yolanda")
    }

    func testSecondHopOnlyPicksSingleSeedCandidates() {
        let cands = [
            CandidateArtist(id: "1", name: "Hub", score: 3, seedNames: ["a", "b"]),
            CandidateArtist(id: "2", name: "Solo", score: 1, seedNames: ["a"]),
        ]
        XCTAssertEqual(secondHopPicks(cands, shuffleSeed: nil).map(\.id), ["2"])
    }
}
