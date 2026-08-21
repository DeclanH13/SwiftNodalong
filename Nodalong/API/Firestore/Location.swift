import FirebaseFirestore
import NodalongKit

private let usersCol = Firestore.firestore().collection("users")

func updateUserLocation(uid: String, geohash: String) async throws {
    try await usersCol.document(uid).updateData([
        "geohash":    geohash,
        "lastActive": Date().timeIntervalSince1970 * 1000,
        "updatedAt":  Date().timeIntervalSince1970 * 1000,
    ])
}

/// Queries the user's geohash cell plus 8 surrounding neighbor cells (9
/// total). Cell precision scales with `radiusKm` (`geohashPrecision`) so the
/// 3×3 query block always covers the requested radius — a fixed precision
/// would cap how far the radius could ever actually reach regardless of the
/// requested value. Mirrors the RN `getNearbyUsers` in nearby.ts.
func getNearbyUsers(geohash: String, excludeUid: String, radiusKm: Double = 10.0) async throws -> [UserProfile] {
    let prefixLen = geohashPrecision(forRadiusKm: radiusKm)
    let ownCell   = String(geohash.prefix(prefixLen))
    let neighbors = geohashNeighbors(ownCell, prefixLen: prefixLen)
    var seen0 = Set<String>()
    let allCells = ([ownCell] + neighbors).filter { seen0.insert($0).inserted }

    let (ownLat, ownLng) = decodeGeohash(geohash)

    // Run one range query per cell in parallel.
    var allDocs: [QueryDocumentSnapshot] = []
    try await withThrowingTaskGroup(of: [QueryDocumentSnapshot].self) { group in
        for cell in allCells {
            group.addTask {
                let snap = try await usersCol
                    .whereField("geohash", isGreaterThanOrEqualTo: cell)
                    .whereField("geohash", isLessThan: cell + "~")
                    .limit(to: 50)
                    .getDocuments()
                return snap.documents
            }
        }
        for try await docs in group { allDocs += docs }
    }

    // Deduplicate, filter by Haversine distance, sort nearest first.
    var seen    = Set<String>()
    var results = [(profile: UserProfile, distance: Double)]()

    for doc in allDocs {
        guard doc.documentID != excludeUid,
              seen.insert(doc.documentID).inserted else { continue }

        var data = doc.data()
        if (data["uid"] as? String) == nil { data["uid"] = doc.documentID }
        if data["bio"]             == nil  { data["bio"] = "" }
        if data["spotlightTracks"] == nil  { data["spotlightTracks"] = [] as [Any] }
        if data["lastActive"]      == nil  { data["lastActive"] = 0.0 }
        if data["createdAt"]       == nil  { data["createdAt"] = 0.0 }
        if data["updatedAt"]       == nil  { data["updatedAt"] = 0.0 }

        guard let profile     = try? Firestore.Decoder().decode(UserProfile.self, from: data),
              let userGeohash = data["geohash"] as? String else { continue }

        let (userLat, userLng) = decodeGeohash(userGeohash)
        let distance = haversineDistance(lat1: ownLat, lng1: ownLng, lat2: userLat, lng2: userLng)
        if distance <= radiusKm {
            results.append((profile: profile, distance: distance))
        }
    }

    return results.sorted { $0.distance < $1.distance }.map { $0.profile }
}
