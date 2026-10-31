import Foundation
import NodalongKit

/// Re-fetches albums whose cached track list was incomplete once their release
/// date has passed — so a pre-saved album fills in by itself, with no one having
/// to open it.
///
/// `MusicDetailCache` remembers every album whose list contained an unplayable
/// track, along with when to look again (`albumRefreshAfter`: the release date,
/// then hourly until Apple has published everything). This asks it which are
/// due, re-fetches them, and heals the user's saved copies and the shared
/// catalog rows from the fresh list. A dictionary scan when nothing is due.
@MainActor
enum ReleaseWatch {
    private static var running = false

    /// Run on app foreground and when Home loads.
    static func checkDue(musicService: AppleMusicService, libraryVM: LibraryViewModel) async {
        guard !running else { return }
        running = true
        defer { running = false }

        for album in await MusicDetailCache.shared.pendingDue() {
            let (id, name, artwork) = (album.id, album.name, album.artwork)
            let real = await MusicDetailCache.shared.tracks(
                albumId: id, releaseDate: album.releaseDate,
                name: name, artist: album.artist, artwork: artwork
            ) {
                (try? await musicService.getAlbumTracks(albumId: id, albumName: name, artwork: artwork)) ?? []
            }
            await libraryVM.healStaleTracks(from: real)
        }
    }
}
