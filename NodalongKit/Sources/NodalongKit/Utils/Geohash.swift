import Foundation

private let base32 = Array("0123456789bcdefghjkmnpqrstuvwxyz")

public struct GeohashBounds: Equatable, Sendable {
    public let minLat: Double
    public let maxLat: Double
    public let minLng: Double
    public let maxLng: Double
}

public func encodeGeohash(lat: Double, lng: Double, precision: Int = 9) -> String {
    precondition((-90...90).contains(lat), "lat \(lat) out of range [-90, 90]")
    precondition((-180...180).contains(lng), "lng \(lng) out of range [-180, 180]")
    precondition((1...12).contains(precision), "precision \(precision) out of range [1, 12]")

    var minLat = -90.0, maxLat = 90.0
    var minLng = -180.0, maxLng = 180.0
    var hash = ""
    var isLng = true
    var bit = 0
    var charIndex = 0

    while hash.count < precision {
        if isLng {
            let mid = (minLng + maxLng) / 2
            if lng >= mid { charIndex = (charIndex << 1) | 1; minLng = mid }
            else          { charIndex = charIndex << 1;        maxLng = mid }
        } else {
            let mid = (minLat + maxLat) / 2
            if lat >= mid { charIndex = (charIndex << 1) | 1; minLat = mid }
            else          { charIndex = charIndex << 1;        maxLat = mid }
        }
        isLng = !isLng
        bit += 1
        if bit == 5 {
            hash.append(base32[charIndex])
            bit = 0
            charIndex = 0
        }
    }
    return hash
}

public func geohashBounds(_ hash: String) -> GeohashBounds {
    var minLat = -90.0, maxLat = 90.0
    var minLng = -180.0, maxLng = 180.0
    var isLng = true

    for char in hash {
        guard let idx = base32.firstIndex(of: char) else { break }
        for bit in stride(from: 4, through: 0, by: -1) {
            let bitValue = (idx >> bit) & 1
            if isLng {
                let mid = (minLng + maxLng) / 2
                if bitValue == 1 { minLng = mid } else { maxLng = mid }
            } else {
                let mid = (minLat + maxLat) / 2
                if bitValue == 1 { minLat = mid } else { maxLat = mid }
            }
            isLng = !isLng
        }
    }
    return GeohashBounds(minLat: minLat, maxLat: maxLat, minLng: minLng, maxLng: maxLng)
}

public func decodeGeohash(_ hash: String) -> (lat: Double, lng: Double) {
    let b = geohashBounds(hash)
    return ((b.minLat + b.maxLat) / 2, (b.minLng + b.maxLng) / 2)
}

public func geohashNeighbors(_ geohash: String, prefixLen: Int) -> [String] {
    let prefix = String(geohash.prefix(prefixLen))
    let bounds = geohashBounds(prefix)
    let latStep = bounds.maxLat - bounds.minLat
    let lngStep = bounds.maxLng - bounds.minLng
    let centerLat = (bounds.minLat + bounds.maxLat) / 2
    let centerLng = (bounds.minLng + bounds.maxLng) / 2

    var seen = Set<String>()
    var neighbors: [String] = []

    for dLat in [-latStep, 0, latStep] {
        for dLng in [-lngStep, 0, lngStep] {
            if dLat == 0 && dLng == 0 { continue }
            let nLat = centerLat + dLat
            if nLat < -90 || nLat > 90 { continue }
            var nLng = centerLng + dLng
            if nLng > 180  { nLng -= 360 }
            if nLng < -180 { nLng += 360 }
            let n = encodeGeohash(lat: nLat, lng: nLng, precision: prefixLen)
            if n != prefix && !seen.contains(n) {
                seen.insert(n)
                neighbors.append(n)
            }
        }
    }
    return neighbors
}

/// Geohash precision whose cell width safely covers a query radius of
/// `radiusKm`, for picking which cells to query before the exact Haversine
/// distance filter runs. `getNearbyUsers` queries a 3×3 block of cells at this
/// precision — the cell width brackets below (≈1.22km / ≈4.89km / ≈39.1km /
/// ≈156km, the standard geohash-precision-to-cell-size table) are chosen so
/// that block always fully contains a circle of the requested radius,
/// regardless of how large the radius slider is set.
public func geohashPrecision(forRadiusKm radiusKm: Double) -> Int {
    switch radiusKm {
    case ..<1.2: return 6   // cell ≈1.22km
    case ..<4.9: return 5   // cell ≈4.89km
    case ..<39:  return 4   // cell ≈39.1km
    default:     return 3   // cell ≈156km
    }
}

public func haversineDistance(lat1: Double, lng1: Double, lat2: Double, lng2: Double) -> Double {
    let r = 6371.0
    let toRad = { (deg: Double) in deg * .pi / 180 }
    let dLat = toRad(lat2 - lat1)
    let dLng = toRad(lng2 - lng1)
    let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(toRad(lat1)) * cos(toRad(lat2))
            * sin(dLng / 2) * sin(dLng / 2)
    let c = 2 * atan2(sqrt(a), sqrt(1 - a))
    return r * c
}
