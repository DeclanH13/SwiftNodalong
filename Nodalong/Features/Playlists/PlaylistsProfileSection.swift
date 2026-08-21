import SwiftUI
import NodalongKit

/// The "Playlists" block shown on the user's own Profile: a horizontal rail of
/// playlist tiles plus a "New" tile.
///
/// Reports a tap back via `onSelectPlaylist` rather than `NavigationLink
/// (value:)` — `ProfileView` is itself reached via a BOOLEAN
/// `.navigationDestination(isPresented:)` push (from `ProfileEntryPoint`),
/// and stacking a type-based `NavigationLink(value:)` push on top of that
/// was unreliable in practice (tapping a playlist would land back on
/// Profile instead of the playlist, only revealing the real destination
/// after popping back once) — the exact same failure mode already found
/// and fixed for the artist discography grid. `ProfileView` owns the
/// resulting `selectedPlaylist` state and its own local, item-based
/// `.navigationDestination(item:)`.
struct PlaylistsProfileSection: View {
    @Environment(FirebaseAuthViewModel.self) private var authVM
    @EnvironmentObject private var playlistsVM: PlaylistsViewModel

    let onSelectPlaylist: (Playlist) -> Void

    @State private var showCreate = false

    private let tileWidth: CGFloat = 132

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Playlists")
                    .font(Font.nodalong.headline)
                    .foregroundStyle(Color.nodalong.textPrimary)
                Spacer()
                Button { showCreate = true } label: {
                    Image(systemName: "plus")
                        .font(Font.nodalong.subheadlineSemibold)
                        .foregroundStyle(Color.nodalong.purpleAccent)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(playlistsVM.playlists) { playlist in
                        Button { onSelectPlaylist(playlist) } label: {
                            PlaylistTile(playlist: playlist).frame(width: tileWidth)
                        }
                        .buttonStyle(.plain)
                    }
                    newTile
                }
                .padding(12)
            }
            .background(Color.nodalong.bgCard)
            .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
        }
        .sheet(isPresented: $showCreate) { CreatePlaylistSheet() }
    }

    private var newTile: some View {
        Button { showCreate = true } label: {
            VStack(spacing: 8) {
                RoundedRectangle(cornerRadius: Corner.container, style: .continuous)
                    .fill(Color.nodalong.bgCard)
                    .frame(width: tileWidth, height: tileWidth)
                    .overlay {
                        Image(systemName: "plus")
                            .font(Font.nodalong.title)
                            .foregroundStyle(Color.nodalong.purpleAccent)
                    }
                Text("New")
                    .font(Font.nodalong.custom(13, .medium))
                    .foregroundStyle(Color.nodalong.textSecondary)
                    .frame(width: tileWidth, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
    }
}

/// A single playlist tile — cover art + title + track count. Fills the width of
/// its container (constrain with `.frame(width:)` in a horizontal rail, or let
/// it fill a grid column).
struct PlaylistTile: View {
    let playlist: Playlist

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                ArtworkThumbnail(url: playlist.coverArtwork, size: geo.size.width)
                    .clipShape(RoundedRectangle(cornerRadius: Corner.artwork, style: .continuous))
                    .overlay(alignment: .bottomTrailing) {
                        if playlist.source == .party {
                            NodalongMark(size: 24)
                                .foregroundStyle(Color.nodalong.textOnAccent)
                                .padding(5)
                                .background(Color.nodalong.purpleAccent, in: Circle())
                                .padding(6)
                        }
                    }
            }
            .aspectRatio(1, contentMode: .fit)
            Text(playlist.title)
                .font(Font.nodalong.custom(13, .bold))
                .foregroundStyle(Color.nodalong.textPrimary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(playlist.trackCount) track\(playlist.trackCount == 1 ? "" : "s")")
                .font(Font.nodalong.custom(11))
                .foregroundStyle(Color.nodalong.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        ScrollView { PlaylistsProfileSection(onSelectPlaylist: { _ in }).padding() }
            .background(Color.nodalong.bgBase)
    }
    .withPreviewEnvironment()
}
#endif
