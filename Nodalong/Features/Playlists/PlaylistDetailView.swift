import SwiftUI
import NodalongKit

/// A single playlist's tracks, with owner-only editing (rename, delete, reorder,
/// remove tracks). Tap a track to play the whole playlist starting there.
struct PlaylistDetailView: View {
    let playlist: Playlist

    @Environment(FirebaseAuthViewModel.self) private var authVM
    @EnvironmentObject private var playerVM:       PlayerViewModel
    @EnvironmentObject private var musicService:   AppleMusicService
    @EnvironmentObject private var spotifyService: SpotifyMusicService
    @EnvironmentObject private var playlistsVM:    PlaylistsViewModel
    @EnvironmentObject private var libraryVM:      LibraryViewModel
    @Environment(\.dismiss) private var dismiss

    /// Whichever backend is actually connected — the play gate must check
    /// this, not hardcode Apple Music.
    private var activeService: any MusicService {
        activeMusicService(playerVM: playerVM, apple: musicService, spotify: spotifyService)
    }

    @State private var tracks: [PlaylistTrack] = []
    @State private var isLoading = true
    @State private var isEditing = false
    @State private var showRename = false
    @State private var renameText = ""

    private var isOwner: Bool { authVM.currentUser?.uid == playlist.ownerUid }

    var body: some View {
        List {
            headerSection
                .listRowBackground(Color.nodalong.bgBase)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .listRowSeparator(.hidden)

            tracksSection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.nodalong.bgBase)
        .safeAreaInset(edge: .bottom) {
            if playerVM.nowPlaying != nil { Color.clear.frame(height: 70) }
        }
        .environment(\.editMode, .constant(isEditing ? .active : .inactive))
        .navigationTitle(playlist.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { if isOwner { ownerToolbar } }
        .alert("Rename Playlist", isPresented: $showRename) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, let uid = authVM.currentUser?.uid else { return }
                Task { await playlistsVM.rename(id: playlist.id, title: trimmed, uid: uid) }
            }
        }
        .task { await loadTracks() }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 12) {
            ArtworkThumbnail(url: playlist.coverArtwork, size: ScreenMetrics.bounds.width - 120)
                .clipShape(RoundedRectangle(cornerRadius: Corner.artwork, style: .continuous))

            VStack(spacing: 4) {
                Text(playlist.title)
                    .font(Font.nodalong.title3Bold)
                    .foregroundStyle(Color.nodalong.textPrimary)
                    .multilineTextAlignment(.center)
                HStack(spacing: 6) {
                    AvatarView(emoji: playlist.ownerAvatarEmoji, colorHex: playlist.ownerAvatarColor, size: 18)
                    Text(playlist.ownerUsername)
                        .font(Font.nodalong.subheadline)
                        .foregroundStyle(Color.nodalong.textSecondary)
                }
                Text("\(tracks.count) track\(tracks.count == 1 ? "" : "s")")
                    .font(Font.nodalong.caption)
                    .foregroundStyle(Color.nodalong.textTertiary)
            }

            if !tracks.isEmpty {
                Button { playAll(startingAt: 0) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "play.fill")
                        Text("Play")
                    }
                    .font(Font.nodalong.subheadlineSemibold)
                    .foregroundStyle(Color.nodalong.textOnAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.nodalong.purpleAccent)
                    .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(!activeService.isAuthenticated)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    // MARK: - Tracks

    @ViewBuilder
    private var tracksSection: some View {
        if isLoading {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
                .listRowBackground(Color.nodalong.bgCard)
                .listRowSeparator(.hidden)
        } else if tracks.isEmpty {
            Text("No tracks yet. Add songs from the Feed, Search, or your Shelf.")
                .font(Font.nodalong.subheadline)
                .foregroundStyle(Color.nodalong.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
                .listRowBackground(Color.nodalong.bgCard)
                .listRowSeparator(.hidden)
        } else {
            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                trackRow(track, at: index)
                    .listRowBackground(Color.nodalong.bgCard)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            }
            .onMove(perform: moveHandler)
            .onDelete(perform: deleteHandler)
        }
    }

    private var moveHandler: ((IndexSet, Int) -> Void)? {
        guard isOwner else { return nil }
        return { offsets, destination in move(from: offsets, to: destination) }
    }

    private var deleteHandler: ((IndexSet) -> Void)? {
        guard isOwner else { return nil }
        return { offsets in delete(at: offsets) }
    }

    private func trackRow(_ track: PlaylistTrack, at index: Int) -> some View {
        HStack(spacing: 12) {
            // Same circular treatment as PlaylistDetailSearchView's rows and
            // MiniPlayerBar — a consistent "playlist" visual language.
            ArtworkThumbnail(url: track.artwork, size: 44, circular: true, isTrack: true)
                .overlay(
                    Circle().strokeBorder(Color.nodalong.textOnAccent.opacity(0.12), lineWidth: 1)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title.isEmpty ? "Unknown" : track.title)
                    .font(Font.nodalong.subheadlineMedium)
                    .foregroundStyle(Color.nodalong.textPrimary)
                    .lineLimit(1)
                Text(track.artist)
                    .font(Font.nodalong.caption)
                    .foregroundStyle(Color.nodalong.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            if let dur = track.duration, dur > 0 {
                Text(formatTrackDuration(dur))
                    .font(Font.nodalong.caption)
                    .foregroundStyle(Color.nodalong.textSecondary)
            }
            TrackActionsMenuButton(
                song:         .from(playlistTrack: track),
                onAddToQueue: { playerVM.addToQueue(.from(playlistTrack: track)) },
                onToggleLike: {
                    guard let uid = authVM.currentUser?.uid else { return }
                    let doc = LibraryTrackDoc(
                        catalogId:     track.catalogId,
                        title:         track.title,
                        artist:        track.artist,
                        album:         track.album,
                        artwork:       track.artwork,
                        uri:           track.uri,
                        sourceService: track.sourceService,
                        isrc:          track.isrc,
                        duration:      track.duration,
                        trackNumber:   track.trackNumber,
                        albumReleaseDate: track.albumReleaseDate,
                        savedAt:       Date().timeIntervalSince1970 * 1000
                    )
                    Task { await libraryVM.toggleLibrary(uid: uid, track: doc) }
                },
                isLiked: libraryVM.isInLibrary(catalogId: track.catalogId, uri: track.uri)
            )
        }
        .padding(.vertical, 6)
        .contentShape(.rect)
        .onTapGesture { playAll(startingAt: index) }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var ownerToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            if isEditing {
                Button("Done") { withAnimation { isEditing = false } }
                    .foregroundStyle(Color.nodalong.purpleAccent)
            } else {
                Menu {
                    Button { withAnimation { isEditing = true } } label: {
                        Label("Reorder / Remove", systemImage: Icons.queue)
                    }
                    Button {
                        renameText = playlist.title
                        showRename = true
                    } label: {
                        Label("Rename", systemImage: Icons.pencilOutline)
                    }
                    Button(role: .destructive) { deletePlaylist() } label: {
                        Label("Delete Playlist", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(Color.nodalong.purpleAccent)
                }
            }
        }
    }

    // MARK: - Actions

    private func loadTracks() async {
        isLoading = true
        tracks = (try? await getPlaylistTracks(playlistId: playlist.id)) ?? []
        isLoading = false
    }

    private func playAll(startingAt index: Int) {
        guard activeService.isAuthenticated, !tracks.isEmpty else { return }
        let songs = tracks.map { Song.from(playlistTrack: $0) }
        Task { await playerVM.play(songs, startingAt: index) }
    }

    private func move(from offsets: IndexSet, to destination: Int) {
        tracks.move(fromOffsets: offsets, toOffset: destination)
        guard let src = offsets.first else { return }
        // After the local move, the item's new index is `destination-1` when it
        // moved downward, else `destination`.
        let newIndex = destination > src ? destination - 1 : destination
        guard tracks.indices.contains(newIndex) else { return }
        let moved  = tracks[newIndex]
        let before = newIndex > 0 ? tracks[newIndex - 1].order : nil
        let after  = newIndex < tracks.count - 1 ? tracks[newIndex + 1].order : nil
        let newOrder = PlaylistOrder.midpoint(before: before, after: after)
        tracks[newIndex].order = newOrder
        Task {
            try? await reorderPlaylistTrack(
                playlistId: playlist.id, trackDocId: moved.id, before: before, after: after
            )
        }
    }

    private func delete(at offsets: IndexSet) {
        let removed = offsets.map { tracks[$0] }
        tracks.remove(atOffsets: offsets)
        Task {
            for r in removed {
                try? await removeTrackFromPlaylist(playlistId: playlist.id, trackDocId: r.id)
            }
            if let uid = authVM.currentUser?.uid { await playlistsVM.reload(uid: uid) }
        }
    }

    private func deletePlaylist() {
        guard let uid = authVM.currentUser?.uid else { return }
        Task {
            await playlistsVM.delete(id: playlist.id, uid: uid)
            dismiss()
        }
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        PlaylistDetailView(playlist: PreviewFixtures.playlists[0])
    }
    .withPreviewEnvironment()
}
#endif
