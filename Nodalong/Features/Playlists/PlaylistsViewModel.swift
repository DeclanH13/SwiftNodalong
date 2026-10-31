import Foundation
import FirebaseAuth
import NodalongKit

/// App-wide state for the current user's playlists.
///
/// Backs the Playlists section on Profile/Home and the "Add to Playlist…"
/// picker reachable from any track's "..." action menu
/// (`TrackActionsMenuButton`), so it's injected once at the tab level (like
/// `FeedViewModel`/`ShelfViewModel`). Mutations write through to Firestore
/// (`Playlists.swift`) and then reload so every surface stays in sync.
@MainActor
final class PlaylistsViewModel: ObservableObject {
    @Published private(set) var playlists: [Playlist] = []
    @Published private(set) var isLoading = false

    /// UID for which data is loaded — prevents redundant reads on tab revisit.
    private var loadedForUid: String? = nil

    /// Restores last session's playlists synchronously so Home's tiles and
    /// Profile's rail render on the first frame instead of a "not generated
    /// yet" placeholder. `Auth.auth().currentUser` is restored from the keychain
    /// synchronously, so the uid is known here. Skipped in previews.
    /// `Playlist.id` is not in its Codable payload (it's the Firestore documentID),
    /// so the snapshot stores ids alongside the playlists and re-injects them.
    private struct StoredPlaylist: Codable {
        var id: String
        var playlist: Playlist
    }
    private static let snapshotKey = "playlists2"

    init() {
        if ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1",
           let uid = Auth.auth().currentUser?.uid,
           let snap = SnapshotStore.load([StoredPlaylist].self, key: Self.snapshotKey, uid: uid) {
            playlists = snap.filter { !$0.id.isEmpty }.map { var p = $0.playlist; p.id = $0.id; return p }
        }
    }

    /// Loads playlists for `uid`. Skips if already loaded for this uid.
    func load(uid: String) async {
        guard !isLoading, loadedForUid != uid else { return }
        isLoading = true
        defer { isLoading = false }
        if let fetched = try? await getUserPlaylists(uid: uid) {
            playlists = fetched
            SnapshotStore.save(fetched.map { StoredPlaylist(id: $0.id, playlist: $0) }, key: Self.snapshotKey, uid: uid)
        }
        loadedForUid = uid
    }

    /// Force-reloads from Firestore (after a mutation).
    func reload(uid: String) async {
        loadedForUid = nil
        await load(uid: uid)
    }

    /// Creates a manual playlist owned by `profile`. Returns the new id.
    @discardableResult
    func create(profile: UserProfile, title: String, visibility: PlaylistVisibility) async -> String? {
        let id = try? await createPlaylist(
            ownerUid: profile.uid,
            ownerUsername: profile.username,
            ownerAvatarEmoji: profile.avatarEmoji,
            ownerAvatarColor: profile.avatarColor,
            title: title,
            visibility: visibility
        )
        await reload(uid: profile.uid)
        return id
    }

    /// Appends `song` to a playlist (attributed to `profile`).
    func addTrack(playlistId: String, song: Song, profile: UserProfile) async {
        PlaylistTracksCache.invalidate(playlistId)
        try? await addTrackToPlaylist(
            playlistId: playlistId, song: song,
            addedByUid: profile.uid, addedByUsername: profile.username
        )
        await reload(uid: profile.uid)
    }

    /// Saves a named, editable copy of a playlist (used for generated ones, which
    /// are rebuilt weekly and can't be edited). Returns the new id.
    @discardableResult
    func saveCopy(of playlist: Playlist, title: String, profile: UserProfile) async -> String? {
        let id = try? await copyPlaylist(
            from: playlist,
            ownerUid: profile.uid,
            ownerUsername: profile.username,
            ownerAvatarEmoji: profile.avatarEmoji,
            ownerAvatarColor: profile.avatarColor,
            title: title
        )
        await reload(uid: profile.uid)
        return id
    }

    func rename(id: String, title: String, uid: String) async {
        // Generated playlists are rebuilt weekly — a name would never survive.
        guard playlists.first(where: { $0.id == id })?.source != .generated else { return }
        try? await updatePlaylistMeta(id: id, title: title)
        await reload(uid: uid)
    }

    func setVisibility(id: String, _ visibility: PlaylistVisibility, uid: String) async {
        try? await updatePlaylistMeta(id: id, visibility: visibility)
        await reload(uid: uid)
    }

    func delete(id: String, uid: String) async {
        guard playlists.first(where: { $0.id == id })?.source != .generated else { return }
        PlaylistTracksCache.invalidate(id)
        try? await deletePlaylist(id: id)
        await reload(uid: uid)
    }

    #if DEBUG
    fileprivate func applyMockPreviewState(playlists: [Playlist]) {
        self.playlists = playlists
    }
    #endif
}

#if DEBUG
extension PlaylistsViewModel {
    /// Playlists VM pre-populated with fixtures for previews.
    static var mockPreview: PlaylistsViewModel {
        let vm = PlaylistsViewModel()
        vm.applyMockPreviewState(playlists: PreviewFixtures.playlists)
        return vm
    }
}
#endif
