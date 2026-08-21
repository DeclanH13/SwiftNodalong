import XCTest
@testable import NodalongKit

final class GeohashTests: XCTestCase {

    // --- Encode ---

    func testEncodeSanFrancisco() {
        // lat 37.7749, lng -122.4194 → well-known prefix "9q8yy"
        let h = encodeGeohash(lat: 37.7749, lng: -122.4194, precision: 5)
        XCTAssertEqual(h, "9q8yy")
    }

    func testEncodeSydney() {
        // lat -33.8688, lng 151.2093
        let h = encodeGeohash(lat: -33.8688, lng: 151.2093, precision: 5)
        XCTAssertEqual(h, "r3gx2")
    }

    func testEncodeEquator() {
        let h = encodeGeohash(lat: 0, lng: 0, precision: 4)
        XCTAssertEqual(h, "s000")
    }

    func testEncodePrecision9() {
        let h = encodeGeohash(lat: 37.7749, lng: -122.4194, precision: 9)
        XCTAssertEqual(h.count, 9)
        XCTAssert(h.hasPrefix("9q8yy"))
    }

    // --- Decode ---

    func testDecodeRoundTrip() {
        let lat = 51.5074, lng = -0.1278 // London
        let h = encodeGeohash(lat: lat, lng: lng, precision: 9)
        let (dLat, dLng) = decodeGeohash(h)
        XCTAssertEqual(dLat, lat, accuracy: 0.001)
        XCTAssertEqual(dLng, lng, accuracy: 0.001)
    }

    // --- Bounds ---

    func testBoundsContainCenter() {
        let (lat, lng) = (37.7749, -122.4194)
        let h = encodeGeohash(lat: lat, lng: lng, precision: 6)
        let b = geohashBounds(h)
        XCTAssert(b.minLat <= lat && lat <= b.maxLat)
        XCTAssert(b.minLng <= lng && lng <= b.maxLng)
    }

    // --- Neighbors ---

    func testNeighborsCount() {
        let h = encodeGeohash(lat: 37.7749, lng: -122.4194, precision: 6)
        let neighbors = geohashNeighbors(h, prefixLen: 6)
        // Should have 8 distinct neighbors (can have fewer at poles)
        XCTAssertEqual(neighbors.count, 8)
        XCTAssertFalse(neighbors.contains(String(h.prefix(6))))
    }

    func testNeighborsDontRepeat() {
        let h = encodeGeohash(lat: 0, lng: 0, precision: 4)
        let neighbors = geohashNeighbors(h, prefixLen: 4)
        XCTAssertEqual(Set(neighbors).count, neighbors.count, "Neighbors must be unique")
    }

    // --- Haversine ---

    func testHaversineKnownDistance() {
        // London to Paris ≈ 340 km
        let d = haversineDistance(lat1: 51.5074, lng1: -0.1278, lat2: 48.8566, lng2: 2.3522)
        XCTAssertEqual(d, 340, accuracy: 10)
    }

    func testHaversineSamePoint() {
        let d = haversineDistance(lat1: 37.7749, lng1: -122.4194, lat2: 37.7749, lng2: -122.4194)
        XCTAssertEqual(d, 0, accuracy: 0.001)
    }

    // --- Precision-for-radius ---

    func testPrecisionForTinyRadius() {
        XCTAssertEqual(geohashPrecision(forRadiusKm: 0.5), 6)
    }

    func testPrecisionForSmallRadius() {
        XCTAssertEqual(geohashPrecision(forRadiusKm: 3), 5)
    }

    func testPrecisionForMediumRadius() {
        XCTAssertEqual(geohashPrecision(forRadiusKm: 20), 4)
    }

    func testPrecisionForLargeRadius() {
        // The radius slider's max (50km) must still resolve to a precision
        // whose 3x3 block actually covers it — not stuck at a fixed value.
        XCTAssertEqual(geohashPrecision(forRadiusKm: 50), 3)
    }

    func testPrecisionAtBracketBoundaries() {
        XCTAssertEqual(geohashPrecision(forRadiusKm: 1.2), 5, "exactly at the boundary rounds down to the wider cell")
        XCTAssertEqual(geohashPrecision(forRadiusKm: 4.9), 4)
        XCTAssertEqual(geohashPrecision(forRadiusKm: 39), 3)
    }

    func testPrecisionMonotonicallyDecreasesWithRadius() {
        let radii: [Double] = [0.5, 1, 3, 4, 10, 20, 40, 50]
        let precisions = radii.map { geohashPrecision(forRadiusKm: $0) }
        for i in 1..<precisions.count {
            XCTAssertLessThanOrEqual(precisions[i], precisions[i - 1],
                "precision must never increase as radius grows")
        }
    }
}
