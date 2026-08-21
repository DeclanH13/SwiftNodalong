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
    @EnvironmentObject private var libraryVM: LibraryViewModel
    @Environment(FirebaseAuthViewModel.self) private var authVM

    /// Whichever backend is actually connected — browsing must route here,
    /// not hardcode Apple Music.
    private var activeService: any MusicService {
        activeMusicService(playerVM: playerVM, apple: musicService, spotify: spotifyService)
    }

    @State private var tracks: [Song] = []
    @State private var isLoading = false

    var body: some View {
        List {
            Section {
                HStack(spacing: 16) {
                    ArtworkThumbnail(url: playlist.artwork, size: 80)
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
                .listRowBackground(Color.nodalong.bgBase)

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
                .listRowBackground(Color.nodalong.bgBase)
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
        .background(Color.nodalong.bgBase)
        // Same reasoning as AlbumDetailSearchView: a safeAreaInset (not a
        // trailing transparent row) so `.insetGrouped`'s bottom-corner
        // rounding always lands on the real last track row.
        .safeAreaInset(edge: .bottom) {
            if playerVM.nowPlaying != nil { Color.clear.frame(height: 70) }
        }
        .navigationTitle(playlist.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard tracks.isEmpty else { return }
            isLoading = true
            tracks = (try? await musicService.getPlaylistTracks(playlistId: playlist.id)) ?? []
            isLoading = false
        }
    }

    @ViewBuilder
    private func playlistTrackRow(track: Song, index: Int) -> some View {
        let isLiked = libraryVM.isInLibrary(catalogId: track.catalogId, uri: track.uri)
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
                onAddToQueue: { playerVM.addToQueue(track) },
                onToggleLike: {
                    guard let uid = authVM.currentUser?.uid else { return }
                    let doc = LibraryTrackDoc(
                        catalogId:     track.catalogId ?? "",
                        title:         track.title,
                        artist:        track.artist,
                        album:         track.album,
                        artwork:       track.artwork,
                        uri:           track.uri,
                        sourceService: .appleMusic,
                        isrc:          track.isrc,
                        duration:      track.duration,
                        trackNumber:   track.trackNumber,
                        savedAt:       Date().timeIntervalSince1970 * 1000
                    )
                    Task { await libraryVM.toggleLibrary(uid: uid, track: doc) }
                },
                isLiked: isLiked
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
