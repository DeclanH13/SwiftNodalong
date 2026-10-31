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
    @Environment(\.dismiss) private var dismiss

    /// Whichever backend is actually connected — the play gate must check
    /// this, not hardcode Apple Music.
    private var activeService: any MusicService {
        activeMusicService(playerVM: playerVM, apple: musicService, spotify: spotifyService)
    }

    @State private var tracks: [PlaylistTrack]
    @State private var isLoading: Bool
    @State private var isEditing = false
    @State private var showRename = false
    @State private var renameText = ""
    @State private var showSaveCopy = false
    @State private var copyName = ""
    @State private var savedCopy = false
    @State private var showInvite = false

    /// Seeds from the on-disk/in-memory track cache synchronously, so a playlist
    /// opened before (or warmed by Home) shows its tracks on the first frame
    /// with no spinner. Without an entry it behaves exactly as before.
    init(playlist: Playlist) {
        self.playlist = playlist
        // A generated playlist is only ever shown from cache if the cached copy is
        // the CURRENT version; a rebuild changes order and contents, and showing the
        // previous build's list looked like the rebuild hadn't happened.
        // `sessionTracks` is someone else's playlist warmed by their
        // profile's rail (`PlaylistTracksCache.prefetch`).
        let cached = playlist.source == .generated
            ? PlaylistTracksCache.freshTracks(for: playlist)
            : PlaylistTracksCache.entry(for: playlist.id)?.restored
        let seeded = cached ?? PlaylistTracksCache.sessionTracks(for: playlist)
        if let seeded {
            _tracks = State(initialValue: seeded)
            _isLoading = State(initialValue: false)
        } else {
            _tracks = State(initialValue: [])
            _isLoading = State(initialValue: true)
        }
    }

    /// Generated playlists are rebuilt weekly and owned by the generator, so they
    /// are read-only: no rename, reorder, remove or delete. "Save a copy" is how
    /// someone keeps a version.
    private var isGenerated: Bool { playlist.source == .generated }

    private var isOwner: Bool { authVM.currentUser?.uid == playlist.ownerUid }

    var body: some View {
        List {
            // Separate sections: if the header shared the tracks' implicit
            // section, the first track would be a mid-section row and lose its
            // rounded top corners.
            Section {
                headerSection
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowSeparator(.hidden)
            }

            Section { tracksSection }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .screenBackground()
        .safeAreaInset(edge: .bottom) {
            if playerVM.nowPlaying != nil { Color.clear.frame(height: 70) }
        }
        .environment(\.editMode, .constant(isEditing ? .active : .inactive))
        .toolbar(.hidden, for: .navigationBar)
        .screenControls { if isOwner { ownerActions } }
        .alert("Rename Playlist", isPresented: $showRename) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, let uid = authVM.currentUser?.uid else { return }
                Task { await playlistsVM.rename(id: playlist.id, title: trimmed, uid: uid) }
            }
        }
        .alert("Save a Copy", isPresented: $showSaveCopy) {
            TextField("Name", text: $copyName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let trimmed = copyName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, let me = authVM.profile else { return }
                Task {
                    if await playlistsVM.saveCopy(of: playlist, title: trimmed, profile: me) != nil {
                        savedCopy = true
                    }
                }
            }
        } message: {
            Text("Keeps today's version as your own playlist, which you can rename and edit.")
        }
        .alert("Saved", isPresented: $savedCopy) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Find it in your playlists.")
        }
        .sheet(isPresented: $showInvite) { InviteFriendSheet(playlist: playlist) }
        .task { await loadTracks() }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 12) {
            ArtworkThumbnail(url: playlist.coverArtwork, size: ScreenMetrics.bounds.width - 120)
                .clipShape(RoundedRectangle(cornerRadius: Corner.playlistCover, style: .continuous))

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
                if isGenerated {
                    Text("Refreshes every Monday")
                        .font(Font.nodalong.caption)
                        .foregroundStyle(Color.nodalong.textTertiary)
                }
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
        guard isOwner, !isGenerated else { return nil }
        return { offsets, destination in move(from: offsets, to: destination) }
    }

    private var deleteHandler: ((IndexSet) -> Void)? {
        guard isOwner, !isGenerated else { return nil }
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
                // Who put this here. `addedByUsername` has been stored on every
                // playlist track since parties shipped but was never rendered —
                // for a generated playlist it's the entire point (these are real
                // people's picks, not an algorithm's), and it's just as useful
                // on a party playlist. Hidden on your own manual playlists,
                // where "added by you" on every row is pure noise.
                if !track.addedByUsername.isEmpty,
                   track.addedByUid != authVM.currentUser?.uid {
                    Text("via \(track.addedByUsername)")
                        .font(Font.nodalong.caption2)
                        .foregroundStyle(Color.nodalong.purpleAccent)
                        .lineLimit(1)
                }
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
                // Suggested music is the one place "not for me" makes sense.
                showsTasteActions: isGenerated
            )
        }
        .padding(.vertical, 6)
        .contentShape(.rect)
        .onTapGesture { playAll(startingAt: index) }
    }

    // MARK: - Toolbar

    /// Plain view, not `ToolbarContent` — there is no toolbar to put it in
    /// any more; the header hosts it in the same trailing position.
    @ViewBuilder
    private var ownerActions: some View {
        Group {
            if isGenerated {
                Menu {
                    Button {
                        let f = DateFormatter()
                        f.dateFormat = "d MMM"
                        copyName = "\(playlist.title) · \(f.string(from: Date()))"
                        showSaveCopy = true
                    } label: {
                        Label("Save a Copy", systemImage: "plus.square.on.square")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(Color.nodalong.purpleAccent)
                }
            } else if isEditing {
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
                    if playlist.source == .manual {
                        Button { showInvite = true } label: {
                            Label("Invite a Friend", systemImage: "person.badge.plus")
                        }
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
        // A generated playlist whose cached version matches the one we were
        // opened with can't have changed — no network at all.
        if isGenerated, let fresh = PlaylistTracksCache.freshTracks(for: playlist) {
            if tracks != fresh { tracks = fresh }
            isLoading = false
            return
        }
        // Someone else's playlist fetched this session at this exact version
        // (opened before, or warmed by their profile's rail): nothing has
        // changed that we could see, so don't pay the reads again.
        if !isOwner, let fresh = PlaylistTracksCache.sessionTracks(for: playlist) {
            if tracks != fresh { tracks = fresh }
            isLoading = false
            return
        }
        // Otherwise revalidate. Only show the spinner when there is nothing to
        // show; a refresh over cached content is silent.
        if tracks.isEmpty { isLoading = true }
        if let fetched = try? await getPlaylistTracks(playlistId: playlist.id) {
            if tracks != fetched { tracks = fetched }
            if isOwner { PlaylistTracksCache.store(fetched, for: playlist) }
            else { PlaylistTracksCache.storeSession(fetched, for: playlist) }
        }
        isLoading = false
    }

    private func playAll(startingAt index: Int) {
        guard activeService.isAuthenticated, !tracks.isEmpty else { return }
        let songs = tracks.map { Song.from(playlistTrack: $0) }
        Task { await playerVM.play(songs, startingAt: index) }
    }

    private func move(from offsets: IndexSet, to destination: Int) {
        PlaylistTracksCache.invalidate(playlist.id)
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
        PlaylistTracksCache.invalidate(playlist.id)
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
