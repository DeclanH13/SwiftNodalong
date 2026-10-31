import SwiftUI
import NodalongKit

/// The full-screen listening-party UI (host + remote). Presented as a cover
/// while `ListeningPartyViewModel.presenting` is true; dismissing it *minimizes*
/// the party (the session stays live) rather than leaving.
///
/// Layout is `List`-based (mirroring `PlaylistDetailView`) so the host gets
/// drag-to-reorder + swipe-to-remove on the shared queue via `.onMove`/`.onDelete`.
struct PartyView: View {
    @EnvironmentObject private var partyVM:        ListeningPartyViewModel
    @Environment(FirebaseAuthViewModel.self) private var authVM
    @EnvironmentObject private var playerVM:       PlayerViewModel
    @EnvironmentObject private var musicService:   AppleMusicService
    @EnvironmentObject private var spotifyService: SpotifyMusicService
    @EnvironmentObject private var playlistsVM:    PlaylistsViewModel
    /// Dismisses this cover, then pushes onto whichever tab the user was on
    /// — see `AppRouter`'s doc comment. Replaced the old nested
    /// `.sheet(item:)` (artist tap) and `.sheet(isPresented:)` ("View
    /// Playlist"), both of which cut the tab bar/mini player off entirely.
    @EnvironmentObject private var router:         AppRouter

    /// Backs `nowPlayingHero`'s square-vs-vinyl branch — same key
    /// `ProfileView`'s picker writes, so a change there applies immediately.
    @AppStorage(albumArtworkStyleKey) private var albumArtworkStyleRaw = AlbumArtworkStyle.vinyl.rawValue

    /// Whichever backend is actually connected — the play gate must check
    /// this, not hardcode Apple Music.
    private var activeService: any MusicService {
        activeMusicService(playerVM: playerVM, apple: musicService, spotify: spotifyService)
    }

    @State private var showAdd = false
    @State private var showEndConfirm = false
    @State private var isEditing = false

    /// After the host ends, `party` is kept but `isActive` flips false — that's
    /// the "party ended" summary state (distinct from a guest `leave()`, which
    /// nils `party`).
    private var isEnded: Bool { !partyVM.isActive && partyVM.party != nil }

    var body: some View {
        ZStack {
            Color.nodalong.bgBase.ignoresSafeArea()
            if isEnded {
                endedSummary
            } else if let party = partyVM.party {
                VStack(spacing: 0) {
                    topBar(party)
                    partyList
                }
            } else {
                ProgressView().tint(.white)
            }
        }
        .environment(\.editMode, .constant(isEditing ? .active : .inactive))
        // Host bridge (broadcast + reconcile) lives in `ListeningPartyViewModel`,
        // scoped to the party session rather than this view — the host can
        // minimize this screen and keep hosting in the background.
        .sheet(isPresented: $showAdd) { PartyAddSheet() }
        .confirmationDialog("End this LP?", isPresented: $showEndConfirm, titleVisibility: .visible) {
            Button("End LP", role: .destructive) { endParty() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The queue will be saved as a playlist everyone can revisit.")
        }
    }

    // MARK: - List

    private var partyList: some View {
        List {
            nowPlayingHero
                // A remote listener has no local `nowPlaying`, so the
                // player's own artist prefetch never runs for them and the
                // hero's artist tap resolved cold. The host already has it.
                .task(id: currentTrack?.uri) {
                    guard !partyVM.isHost, let track = currentTrack else { return }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    guard !Task.isCancelled else { return }
                    await CatalogPrefetch.pending(song: .from(partyQueueTrack: track),
                                                  playerVM: playerVM, service: musicService)
                }
                .listRowBackground(Color.nodalong.bgBase)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 12, trailing: 16))
                .listRowSeparator(.hidden)

            participantsRow
                .listRowBackground(Color.nodalong.bgBase)
                .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
                .listRowSeparator(.hidden)

            if partyVM.liveAvailable {
                listenModeRow
                    .listRowBackground(Color.nodalong.bgBase)
                    .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
                    .listRowSeparator(.hidden)
            }

            if !partyVM.liveAvailable {
                liveUnavailableNotice
                    .listRowBackground(Color.nodalong.bgBase)
                    .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
                    .listRowSeparator(.hidden)
            }

            if partyVM.isHost && !playerVM.isPartyDriven && !partyVM.queue.isEmpty {
                playQueueButton
                    .listRowBackground(Color.nodalong.bgBase)
                    .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 8, trailing: 20))
                    .listRowSeparator(.hidden)
            }

            // Its own `Section` (matching `QueueView`'s "Now Playing" /
            // "Up Next" split) so `.insetGrouped` rounds *this* section's
            // own top/bottom corners independently of the `bgBase` header
            // content above — rather than one section spanning both, whose
            // rounding would land on whichever row happens to be first/last
            // regardless of which color group it's actually in.
            Section {
                if partyVM.upcomingQueue.isEmpty {
                    Text(partyVM.canAddToQueue ? "Queue's empty — add the first track." : "The host hasn't queued anything yet.")
                        .font(Font.nodalong.subheadline).foregroundStyle(Color.nodalong.textSecondary)
                        .listRowBackground(Color.nodalong.bgCard)
                        .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20))
                        .listRowSeparator(.hidden)
                } else {
                    ForEach(partyVM.upcomingQueue) { track in
                        queueRow(track)
                            .listRowBackground(Color.nodalong.bgCard)
                            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    }
                    .onMove(perform: moveHandler)
                    .onDelete(perform: deleteHandler)
                }
            } header: {
                queueHeader
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        // A `.safeAreaInset`, not a trailing transparent list row — see the
        // same fix + rationale in `AlbumDetailSearchView`/`ShelfView`.
        .safeAreaInset(edge: .bottom) {
            if playerVM.nowPlaying != nil { Color.clear.frame(height: 70) }
        }
    }

    private var moveHandler: ((IndexSet, Int) -> Void)? {
        guard partyVM.isHost else { return nil }
        return { offsets, destination in partyVM.moveQueueTrack(fromOffsets: offsets, toOffset: destination) }
    }

    private var deleteHandler: ((IndexSet) -> Void)? {
        guard partyVM.isHost else { return nil }
        return { offsets in offsets.map { partyVM.upcomingQueue[$0] }.forEach { partyVM.removeFromQueue($0) } }
    }

    // MARK: - Top bar

    private func topBar(_ party: ListeningParty) -> some View {
        HStack(spacing: 12) {
            Button { partyVM.presenting = false } label: {
                Image(systemName: "chevron.down")
                    .font(Font.nodalong.headline).foregroundStyle(Color.nodalong.textPrimary)
                    .frame(width: 40, height: 40)
                    .background(Color.nodalong.bgCard, in: Circle())
            }
            VStack(alignment: .leading, spacing: 2) {
                MarqueeText(text: party.title, font: Font.nodalong.headline, color: Color.nodalong.textPrimary)
                HStack(spacing: 5) {
                    Circle().fill(Color.nodalong.gold).frame(width: 7, height: 7)
                    Text("LIVE · hosted by \(party.hostUsername)")
                        .font(Font.nodalong.caption).foregroundStyle(Color.nodalong.textSecondary)
                }
            }
            Spacer()
            if partyVM.isHost {
                if isEditing {
                    Button("Done") { withAnimation { isEditing = false } }
                        .font(Font.nodalong.subheadlineSemibold).foregroundStyle(Color.nodalong.purpleAccent)
                } else {
                    Button("Edit") { withAnimation { isEditing = true } }
                        .font(Font.nodalong.subheadlineSemibold).foregroundStyle(Color.nodalong.purpleAccent)
                    Button("End") { showEndConfirm = true }
                        .font(Font.nodalong.subheadlineSemibold).foregroundStyle(Color.nodalong.error)
                }
            } else {
                Button("Leave") { partyVM.leave() }
                    .font(Font.nodalong.subheadlineSemibold).foregroundStyle(Color.nodalong.error)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color.nodalong.bgBase)
    }

    // MARK: - Rows / sections

    /// Prominent Now Playing hero — large artwork + title + tappable artist.
    ///
    /// Same square-vs-vinyl branch as `NowPlayingView.artworkSection` (this
    /// plays the identical "what's playing, big" role) — spin uses
    /// `heroIsPlaying`, which reads the host's own local playback for the
    /// host and the RTDB-broadcast `isPlaying` flag for a remote (who has
    /// no local playback state of their own in this DJ model — see
    /// `currentTrack`'s doc comment).
    private var nowPlayingHero: some View {
        let track = currentTrack
        let side = min(ScreenMetrics.bounds.width - 80, 360)
        return VStack(spacing: 14) {
            Group {
                if AlbumArtworkStyle(rawValue: albumArtworkStyleRaw) == .vinyl {
                    VinylArtworkView(url: track?.artwork ?? "", size: side)
                        .spinWhilePlaying(heroIsPlaying)
                        .clipShape(Circle())
                        .compositingGroup()
                } else {
                    ArtworkThumbnail(url: track?.artwork ?? "", size: side)
                        .clipShape(RoundedRectangle(cornerRadius: Corner.artwork, style: .continuous))
                }
            }
            .shadow(color: .black.opacity(0.3), radius: 16, y: 6)
            VStack(spacing: 5) {
                Text("NOW PLAYING")
                    .font(Font.nodalong.caption2Bold).kerning(1.2)
                    .foregroundStyle(Color.nodalong.purpleAccent)
                Text(track?.title ?? "Nothing playing yet")
                    .font(Font.nodalong.title3Bold).foregroundStyle(Color.nodalong.textPrimary)
                    .multilineTextAlignment(.center).lineLimit(2)
                if let track {
                    Button { openArtist(track) } label: {
                        // Explicit width — MarqueeText needs a genuinely
                        // bounded container to detect overflow against; a
                        // plain Text/Button inside this VStack would just
                        // hug its own natural width and never trigger a
                        // scroll, even for a long artist name.
                        MarqueeText(text: track.artist, font: Font.nodalong.subheadline, color: Color.nodalong.textSecondary, alignment: .center)
                            .frame(width: side)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private var participantsRow: some View {
        HStack(spacing: -8) {
            ForEach(partyVM.participants) { p in
                AvatarView(emoji: p.avatarEmoji, colorHex: p.avatarColor, size: 34)
                    .overlay(Circle().strokeBorder(Color.nodalong.bgBase, lineWidth: 2))
            }
            Spacer()
            Text("\(partyVM.participants.count) here")
                .font(Font.nodalong.caption).foregroundStyle(Color.nodalong.textSecondary)
        }
    }

    /// Sync/in-room counts, plus (for guests) the control to choose how they're
    /// listening. The host is always the source, so they see only the counts.
    @ViewBuilder
    private var listenModeRow: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                NodalongMark(size: 14)
                Text("\(partyVM.syncListenerCount) in sync • \(partyVM.inRoomCount) in the room")
                    .font(Font.nodalong.caption)
                Spacer()
            }
            .foregroundStyle(Color.nodalong.textSecondary)

            if !partyVM.isHost {
                if !musicService.canPlayFullTracks {
                    Text("Apple Music subscription required to play in sync")
                        .font(Font.nodalong.caption2)
                        .foregroundStyle(Color.nodalong.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if partyVM.remoteNowPlaying?.isPreviewPlayback == true {
                    // The host isn't a subscriber (30s preview fallback) —
                    // syncing would cycle every ~30s as their preview loops.
                    Text("Sync unavailable — \(partyVM.party?.hostUsername ?? "the host") isn't on Apple Music")
                        .font(Font.nodalong.caption2)
                        .foregroundStyle(Color.nodalong.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Picker("Listening", selection: Binding(
                        get: { partyVM.myListenMode },
                        set: { partyVM.setListenMode($0) }
                    )) {
                        Text("In the room").tag(PartyListenMode.inRoom)
                        Text("Play in sync").tag(PartyListenMode.sync)
                    }
                    .pickerStyle(.segmented)
                }
            }
        }
    }

    private var liveUnavailableNotice: some View {
        Text("Live sync (who's here, now playing) needs Realtime Database enabled for this Firebase project. The queue still works.")
            .font(Font.nodalong.caption)
            .foregroundStyle(Color.nodalong.gold)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.nodalong.gold.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
    }

    private var playQueueButton: some View {
        Button { startPlayback() } label: {
            Label("Play Queue", systemImage: "play.fill")
                .font(Font.nodalong.subheadlineSemibold).foregroundStyle(Color.nodalong.textOnAccent)
                .frame(maxWidth: .infinity).padding(.vertical, 12)
                .background(Color.nodalong.purpleAccent)
                .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!activeService.isAuthenticated)
    }

    private var queueHeader: some View {
        HStack {
            Text("Up Next").font(Font.nodalong.headline).foregroundStyle(Color.nodalong.textPrimary)
            Spacer()
            if partyVM.canAddToQueue {
                Button { showAdd = true } label: {
                    Label("Add", systemImage: "plus").font(Font.nodalong.subheadlineSemibold)
                        .foregroundStyle(Color.nodalong.purpleAccent)
                }
            } else {
                // `canAddToQueue` is only false for a non-host guest in an
                // `.ownerOnly` LP (see its own doc comment — host is always
                // true) — without this, the Add button just silently isn't
                // there, with nothing explaining why.
                Text("Only the host can add songs")
                    .font(Font.nodalong.caption)
                    .foregroundStyle(Color.nodalong.textTertiary)
            }
        }
    }

    private func queueRow(_ track: PartyQueueTrack) -> some View {
        HStack(spacing: 12) {
            ArtworkThumbnail(url: track.artwork, size: 44, isTrack: true)
            Button { openArtist(track) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title.isEmpty ? "Unknown" : track.title)
                        .font(Font.nodalong.subheadlineMedium).foregroundStyle(Color.nodalong.textPrimary).lineLimit(1)
                    Text("\(track.artist) · added by \(track.addedByUsername)")
                        .font(Font.nodalong.caption).foregroundStyle(Color.nodalong.textSecondary).lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            Spacer()
            if track.played {
                Image(systemName: Icons.checkmark).font(Font.nodalong.caption).foregroundStyle(Color.nodalong.textTertiary)
            }
        }
        .padding(.vertical, 6)
        .opacity(track.played ? 0.5 : 1)
    }

    // MARK: - Party ended summary

    private var endedSummary: some View {
        VStack(spacing: 18) {
            Spacer()
            // A vinyl disc, not the old party-popper — matches the LP
            // rename instead of reading as a disconnected leftover.
            Image(systemName: Icons.discSharp)
                .font(.system(size: 44)).foregroundStyle(Color.nodalong.purpleAccent)
            Text("LP ended").font(Font.nodalong.title2Bold).foregroundStyle(Color.nodalong.textPrimary)

            if let playlist = partyVM.endedPlaylist {
                VStack(spacing: 10) {
                    ArtworkThumbnail(url: playlist.coverArtwork, size: min(ScreenMetrics.bounds.width - 140, 240))
                        .clipShape(RoundedRectangle(cornerRadius: Corner.playlistCover, style: .continuous))
                    // Previously wrapped freely (no lineLimit) rather than
                    // truncating — a one-time, single-glance summary screen
                    // reads better with the same scrolling-title treatment
                    // as the rest of the app's prominent titles than with
                    // an inconsistent 2-line wrap here alone.
                    MarqueeText(text: playlist.title, font: Font.nodalong.headline, color: Color.nodalong.textPrimary, alignment: .center)
                        .frame(width: min(ScreenMetrics.bounds.width - 140, 240))
                    Text("Saved as a playlist · \(playlist.trackCount) track\(playlist.trackCount == 1 ? "" : "s")")
                        .font(Font.nodalong.caption).foregroundStyle(Color.nodalong.textSecondary)
                }
                Button {
                    // `dismissEndedSummary()` (not a bare flag flip) is
                    // deliberate — it already clears `endedPlaylist`/`party`/
                    // `queue`, the same cleanup "Done" performs, so reopening
                    // the party cover later can't show stale ended-state.
                    router.dismissThenPush(playlist) { partyVM.dismissEndedSummary() }
                } label: {
                    Text("View Playlist")
                        .font(Font.nodalong.subheadlineSemibold).foregroundStyle(Color.nodalong.textOnAccent)
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(Color.nodalong.purpleAccent)
                        .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 40)
            } else {
                Text("No songs were queued, so there's no playlist to save.")
                    .font(Font.nodalong.subheadline).foregroundStyle(Color.nodalong.textSecondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 40)
            }

            Spacer()
            Button("Done") { partyVM.dismissEndedSummary() }
                .font(Font.nodalong.subheadlineSemibold).foregroundStyle(Color.nodalong.textSecondary)
                .padding(.bottom, 24)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func startPlayback() {
        let songs = partyVM.playableSongs
        guard !songs.isEmpty, activeService.isAuthenticated else { return }
        let start = partyVM.queue.firstIndex { !$0.played } ?? 0
        Task {
            await playerVM.play(songs, startingAt: start)
            // Hand ownership to reconcile (also flips `isPartyDriven`, hiding this button).
            playerVM.reconcileQueue(with: partyVM.playableSongs)
        }
    }

    private func endParty() {
        Task {
            await partyVM.endPartyAndFreeze()
            if let uid = authVM.currentUser?.uid { await playlistsVM.reload(uid: uid) }
        }
    }

    /// Dismisses this cover, then pushes onto whichever tab the user was on
    /// — shows a provisional header instantly via `ResolvingArtistsView`,
    /// resolving in the background through the SAME cache-then-fallback
    /// cascade `NowPlayingView`'s own artist tap uses (`resolvePendingArtists`).
    /// Replaces the old `loadArtist(name:)`, which only ever did a fuzzy
    /// `searchAll` with a blocking wait before anything appeared — this is
    /// both faster (instant placeholder) and more precise (the real MusicKit
    /// relationship lookup, when available) than what it replaces.
    private func openArtist(_ track: PartyQueueTrack) {
        router.dismissThenPush(
            PendingArtistResolve(
                trackTitle: track.title, artist: track.artist,
                catalogId: track.catalogId, isrc: track.isrc, uri: track.uri
            )
        ) { partyVM.presenting = false }
    }

    // MARK: - Helpers

    /// What to show in the Now Playing hero: the host reads its own player;
    /// remotes read the shared pointer.
    private var currentTrack: PartyQueueTrack? {
        if partyVM.isHost, let np = playerVM.nowPlaying {
            return partyVM.queue.first { $0.catalogId == np.catalogId }
                ?? PartyQueueTrack(catalogId: np.catalogId ?? "", title: np.title, artist: np.artist,
                                   album: np.album, artwork: np.artwork, uri: np.uri,
                                   addedByUid: "", addedByUsername: "", addedAt: 0, order: 0)
        }
        return partyVM.displayedNowPlaying
    }

    /// Drives `nowPlayingHero`'s spin — the host has real local playback
    /// state (`playerVM.isPlaying`); a remote has none of their own in this
    /// DJ model, so it reads the RTDB-broadcast flag instead (`partyVM`'s
    /// `remoteNowPlaying.isPlaying`, `false` if nothing's been received yet).
    private var heroIsPlaying: Bool {
        partyVM.isHost ? playerVM.isPlaying : (partyVM.remoteNowPlaying?.isPlaying ?? false)
    }
}

// MARK: - Start party

/// Sheet to configure and start a new party.
struct StartPartySheet: View {
    @EnvironmentObject private var partyVM:  ListeningPartyViewModel
    @Environment(FirebaseAuthViewModel.self) private var authVM
    @EnvironmentObject private var playerVM: PlayerViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var permission: PartyPermission = .anyoneCanAdd
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("LP name", text: $title).foregroundStyle(Color.nodalong.textPrimary)
                }
                .listRowBackground(Color.nodalong.bgCard)

                // What is playing right now — the first track of the LP.
                Section("Now Playing") {
                    if let current = playerVM.currentItem {
                        QueueRow(song: current.song, isCurrent: true)
                    } else {
                        Text("Nothing playing — you can add songs once the LP starts.")
                            .font(Font.nodalong.subheadline)
                            .foregroundStyle(Color.nodalong.textSecondary)
                    }
                }
                .listRowBackground(Color.nodalong.bgCard)

                Section("Who can add songs") {
                    Picker("Who can add", selection: $permission) {
                        Text("Anyone").tag(PartyPermission.anyoneCanAdd)
                        Text("Only me").tag(PartyPermission.ownerOnly)
                    }
                    .pickerStyle(.segmented)
                }
                .listRowBackground(Color.nodalong.bgCard)

                // Read-only: this is exactly what starting the LP shares —
                // `createAndEnter` seeds the party with the playing track
                // followed by this Up Next. Reorder or remove on the queue
                // screen before starting.
                if !playerVM.upNext.isEmpty {
                    Section("Up Next · \(playerVM.upNext.count)") {
                        ForEach(playerVM.upNext) { item in
                            QueueRow(song: item.song, isCurrent: false)
                        }
                    }
                    .listRowBackground(Color.nodalong.bgCard)
                }
            }
            .scrollContentBackground(.hidden)
            .screenBackground()
            .navigationTitle("Start an LP")
            .navigationBarTitleDisplayMode(.inline)
            // Let the mesh show through the bar instead of the opaque app-wide nav fill.
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.foregroundStyle(Color.nodalong.textSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") { start() }
                        .foregroundStyle(Color.nodalong.purpleAccent)
                        .disabled(busy)
                }
            }
        }
    }

    private func start() {
        guard let me = authVM.profile, !busy else { return }
        busy = true
        Task {
            await partyVM.createAndEnter(
                title: title.trimmingCharacters(in: .whitespaces), permission: permission,
                me: me, playerVM: playerVM
            )
            busy = false
            dismiss()
        }
    }
}

// MARK: - Add songs to the party

/// In-party search sheet — find a track and add it to the shared queue. Works
/// for host and (permission-permitting) guests; cross-service by design since
/// the queue stores service-neutral ISRC identity.
struct PartyAddSheet: View {
    @EnvironmentObject private var partyVM:        ListeningPartyViewModel
    @EnvironmentObject private var playerVM:       PlayerViewModel
    @EnvironmentObject private var musicService:   AppleMusicService
    @EnvironmentObject private var spotifyService: SpotifyMusicService
    @Environment(\.dismiss) private var dismiss

    /// Whichever backend is actually connected — search must route here,
    /// not hardcode Apple Music.
    private var activeService: any MusicService {
        activeMusicService(playerVM: playerVM, apple: musicService, spotify: spotifyService)
    }

    @State private var query = ""
    @State private var results: [Song] = []
    @State private var searching = false
    @State private var addedIds = Set<String>()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: Icons.search).foregroundStyle(Color.nodalong.textSecondary)
                    TextField("Search songs", text: $query)
                        .foregroundStyle(Color.nodalong.textPrimary)
                        .submitLabel(.search)
                        .onSubmit { runSearch() }
                }
                .padding(12)
                .background(Color.nodalong.bgCard)
                .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
                .padding(.horizontal, 16).padding(.top, 12)

                if searching {
                    ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(results) { song in
                            Button { add(song) } label: { row(song) }
                                .listRowBackground(Color.nodalong.bgCard)
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                }
            }
            .screenBackground()
            .navigationTitle("Add to Queue")
            .navigationBarTitleDisplayMode(.inline)
            // Let the mesh show through the bar instead of the opaque app-wide nav fill.
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.foregroundStyle(Color.nodalong.purpleAccent)
                }
            }
        }
    }

    private func row(_ song: Song) -> some View {
        HStack(spacing: 12) {
            ArtworkThumbnail(url: song.artwork, size: 44, isTrack: true)
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title).font(Font.nodalong.subheadlineMedium).foregroundStyle(Color.nodalong.textPrimary).lineLimit(1)
                Text(song.artist).font(Font.nodalong.caption).foregroundStyle(Color.nodalong.textSecondary).lineLimit(1)
            }
            Spacer()
            Image(systemName: addedIds.contains(song.id) ? Icons.checkmarkCircle : "plus.circle")
                .foregroundStyle(addedIds.contains(song.id) ? Color.nodalong.gold : Color.nodalong.purpleAccent)
        }
    }

    private func runSearch() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, activeService.isAuthenticated else { return }
        searching = true
        Task {
            let hits = (try? await activeService.searchTracks(q, maxResults: 25)) ?? []
            results = hits
            searching = false
        }
    }

    private func add(_ song: Song) {
        partyVM.addToQueue(song)
        addedIds.insert(song.id)
    }
}

#if DEBUG
#Preview("Party") {
    PartyView().withPreviewEnvironment()
}
#endif
