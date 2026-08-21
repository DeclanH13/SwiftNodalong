import Foundation
import NodalongKit

/// State for the Near Me tab — nearby users plus their featured tracks.
///
/// Calls `getNearbyUsers(geohash:)` to fetch users within `radiusKm` (geohash
/// prefix neighbours + haversine filter). For any user without a spotlight,
/// asynchronously loads their top recent track in parallel so the user-tap
/// sheet always has something to show.
///
/// Reads: `getNearbyUsers`, `getYourMusicFeed` in API/Firestore.
/// Drives: NearMeCanvasView (avatar layout), NearMeUserSheet (selected user).
@MainActor
final class NearMeViewModel: ObservableObject {
    @Published private(set) var nearbyUsers:     [UserProfile]  = []
    @Published private(set) var featuredTracks:  [String: Post] = [:]
    @Published private(set) var isLoading       = false
    @Published private(set) var errorMessage:    String? = nil
    @Published var radiusKm: Double = 10.0

    /// Set once data has been loaded for the current session. Prevents
    /// redundant Firestore reads when `.task` re-fires on tab re-visit.
    private var hasLoaded = false

    /// Geohash that was used for the most recent successful load. If the
    /// user moves significantly (different geohash), a re-load is triggered
    /// even without `forceReload`.
    private var loadedGeohash: String? = nil

    /// Loads nearby users. Skips the fetch if data for the same geohash is
    /// already loaded — pass `forceReload: true` to bypass (e.g. radius change).
    func load(geohash: String, excludeUid: String, forceReload: Bool = false) async {
        guard forceReload || !hasLoaded || loadedGeohash != geohash else { return }
        isLoading    = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let users = try await getNearbyUsers(geohash: geohash, excludeUid: excludeUid, radiusKm: radiusKm)
            nearbyUsers = users
            hasLoaded      = true
            loadedGeohash  = geohash
            await loadFeaturedTracks(for: users)
        } catch {
            errorMessage = "Could not load nearby listeners"
            nearbyUsers  = []
        }
    }

    // MARK: - Private

    #if DEBUG
    fileprivate func applyMockPreviewState(users: [UserProfile]) {
        self.nearbyUsers = users
    }
    #endif

    private func loadFeaturedTracks(for users: [UserProfile]) async {
        let usersWithoutSpotlight = users.filter { $0.spotlightTracks.isEmpty }
        guard !usersWithoutSpotlight.isEmpty else { return }

        await withTaskGroup(of: (String, Post?).self) { group in
            for user in usersWithoutSpotlight {
                group.addTask {
                    let feed = try? await getYourMusicFeed(uid: user.uid)
                    return (user.uid, feed?.first)
                }
            }
            for await (uid, post) in group {
                if let post {
                    featuredTracks[uid] = post
                }
            }
        }
    }
}

#if DEBUG
extension NearMeViewModel {
    /// NearMe VM pre-populated with fixture nearby users for previews.
    static var mockPreview: NearMeViewModel {
        let vm = NearMeViewModel()
        vm.applyMockPreviewState(users: PreviewFixtures.nearbyProfiles)
        return vm
    }
}
#endif
