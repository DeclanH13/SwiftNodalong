import Foundation
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

    /// Loads playlists for `uid`. Skips if already loaded for this uid.
    func load(uid: String) async {
        guard !isLoading, loadedForUid != uid else { return }
        isLoading = true
        defer { isLoading = false }
        playlists = (try? await getUserPlaylists(uid: uid)) ?? []
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
        try? await addTrackToPlaylist(
            playlistId: playlistId, song: song,
            addedByUid: profile.uid, addedByUsername: profile.username
        )
        await reload(uid: profile.uid)
    }

    func rename(id: String, title: String, uid: String) async {
        try? await updatePlaylistMeta(id: id, title: title)
        await reload(uid: uid)
    }

    func setVisibility(id: String, _ visibility: PlaylistVisibility, uid: String) async {
        try? await updatePlaylistMeta(id: id, visibility: visibility)
        await reload(uid: uid)
    }

    func delete(id: String, uid: String) async {
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
