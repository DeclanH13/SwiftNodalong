import SwiftUI
import NodalongKit

/// Track list for a Made For You playlist mix (`PlaylistResult`).
///
/// Mirrors `AlbumDetailSearchView`'s shape (header row + `List` of tracks +
/// tap-to-play-in-context) — pushed from Home's "Made For You" rail instead
/// of resolving-and-playing at tap time, so the user can see what's actually
/// in the playlist before anything plays.
struct PlaylistDetailSearchView: View {
    let playlist: PlaylistResult

    @EnvironmentObject private var musicService:   AppleMusicService
    @EnvironmentObject private var spotifyService: SpotifyMusicService
    @EnvironmentObject private var playerVM:  PlayerViewModel

    /// Whichever backend is actually connected — browsing must route here,
    /// not hardcode Apple Music.
    private var activeService: any MusicService {
        activeMusicService(playerVM: playerVM, apple: musicService, spotify: spotifyService)
    }

    @State private var tracks: [Song]
    @State private var isLoading = false

    /// Seeds from a prefetched track list synchronously so a warmed playlist
    /// opens with its tracks on the first frame.
    init(playlist: PlaylistResult) {
        self.playlist = playlist
        _tracks = State(initialValue: MusicDetailCache.peekPlaylistTracks(id: playlist.id) ?? [])
    }

    var body: some View {
        VStack(spacing: 0) {
        List {
            Section {
                HStack(spacing: 16) {
                    ArtworkThumbnail(url: playlist.artwork, size: 80)
                        .clipShape(RoundedRectangle(cornerRadius: Corner.playlistCover, style: .continuous))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(playlist.name)
                            .font(Font.nodalong.title3Bold)
                            .foregroundStyle(Color.nodalong.textPrimary)
                            .lineLimit(2)
                        if !playlist.curatorName.isEmpty {
                            Text(playlist.curatorName)
                                .font(Font.nodalong.subheadline)
                                .foregroundStyle(Color.nodalong.textSecondary)
                        }
                        Text("\(tracks.count) tracks")
                            .font(Font.nodalong.caption)
                            .foregroundStyle(Color.nodalong.textSecondary)
                    }
                }
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)

                Button {
                    guard activeService.isAuthenticated, !tracks.isEmpty else { return }
                    Task { await playerVM.play(tracks, startingAt: 0) }
                } label: {
                    Label("Play", systemImage: "play.fill")
                        .font(Font.nodalong.subheadlineMedium)
                        .foregroundStyle(Color.nodalong.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .disabled(tracks.isEmpty)
                .listRowBackground(Color.clear)
            }

            Section("Tracks") {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.nodalong.bgCard)
                } else {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { idx, track in
                        playlistTrackRow(track: track, index: idx)
                            .listRowBackground(Color.nodalong.bgCard)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .screenBackground()
        // Same reasoning as AlbumDetailSearchView: a safeAreaInset (not a
        // trailing transparent row) so `.insetGrouped`'s bottom-corner
        // rounding always lands on the real last track row.
        .safeAreaInset(edge: .bottom) {
            if playerVM.nowPlaying != nil { Color.clear.frame(height: 70) }
        }
        }
        .screenBackground()
        .toolbar(.hidden, for: .navigationBar)
        .screenControls()
        .task {
            guard tracks.isEmpty else { return }
            isLoading = true
            tracks = await MusicDetailCache.shared.playlistTracks(id: playlist.id) {
                (try? await musicService.getPlaylistTracks(playlistId: playlist.id)) ?? []
            }
            isLoading = false
        }
    }

    @ViewBuilder
    private func playlistTrackRow(track: Song, index: Int) -> some View {
        HStack(spacing: 12) {
            // Circular artwork instead of a track number — playlist order
            // isn't a meaningful "position" the way an album track number is,
            // and every other track surface in the app leads with artwork.
            // Mirrors MiniPlayerBar's circular treatment (minus the spin —
            // this is a static list row, not the actively-playing bar).
            ArtworkThumbnail(url: track.artwork, size: 44, circular: true, isTrack: true)
                .overlay(
                    Circle().strokeBorder(Color.nodalong.textOnAccent.opacity(0.12), lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(Font.nodalong.subheadlineMedium).foregroundStyle(Color.nodalong.textPrimary).lineLimit(1)
                Text(track.artist)
                    .font(Font.nodalong.caption).foregroundStyle(Color.nodalong.textSecondary).lineLimit(1)
            }
            Spacer()
            if let dur = track.duration {
                Text(formatTrackDuration(dur))
                    .font(Font.nodalong.caption)
                    .foregroundStyle(Color.nodalong.textSecondary)
            }
            TrackActionsMenuButton(
                song:         track,
                onAddToQueue: { playerVM.addToQueue(track) }
            )
        }
        .contentShape(.rect)
        .onTapGesture {
            guard activeService.isAuthenticated else { return }
            // Play within the playlist: load the whole list, start here.
            Task { await playerVM.play(tracks, startingAt: index) }
        }
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        PlaylistDetailSearchView(playlist: PlaylistResult(
            id: "pl.preview",
            name: "New Music Mix",
            curatorName: "Apple Music",
            artwork: PreviewFixtures.album.artwork,
            sourceService: .appleMusic
        ))
    }
    .withPreviewEnvironment()
}
#endif
