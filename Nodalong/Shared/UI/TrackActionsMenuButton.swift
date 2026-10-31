import SwiftUI
import NodalongKit

/// Visible "…" button hosting every available track action for the row/card
/// it's attached to. Replaces the old long-press menu (`QueueContextMenu`,
/// removed) — that affordance was undiscoverable, with no visual cue it
/// existed.
///
/// The button is the trigger; `TrackActionsSheet` is the menu. That used to be
/// a system `confirmationDialog` — text-only, styled entirely by iOS, and with
/// nowhere to put the album or artist. It is now our own surface.
///
/// **The sheet derives its own state**, so this takes only a `Song` and an
/// optional queue closure. Before, every call site passed liked/spotlit state
/// and their matching closures, and four of them hand-rolled an identical
/// `LibraryTrackDoc` inline to do it.
struct TrackActionsMenuButton: View {
    /// Required: the menu's shelf, spotlight, album and artist rows are all
    /// derived from it. Every call site already had one.
    let song: Song
    var onAddToQueue: (() -> Void)? = nil
    /// Overrides the glyph colour. Needed on a spotlit `TrackCard.row`, whose
    /// surface is appearance-independent gold foil — the default here is a
    /// mode-aware token, near-white in dark mode, which disappears on gold.
    var tint: Color? = nil
    /// Adds "Play less of this artist" / "Never suggest this artist" — only
    /// offered on generated playlists, where they mean something.
    var showsTasteActions: Bool = false

    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var musicService: AppleMusicService
    @EnvironmentObject private var playerVM: PlayerViewModel
    @State private var showMenu = false
    @State private var showPlaylistPicker = false
    @State private var showSendSheet = false

    /// Presenting and dismissing the cover with the system transition off, so
    /// only `TrackActionsSheet`'s own scrim-fade and card-slide run. Scoped to
    /// the one state change via `withTransaction` rather than a `.transaction`
    /// modifier, which would flatten animations for everything else here too.
    private func setMenu(_ open: Bool) {
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { showMenu = open }
    }

    var body: some View {
        Button {
            // TEMPORARY [Nodalong.Diag] — splits the tap into its two halves
            // so a surviving hang names itself rather than needing a theory.
            // Remove once the first-press delay is confirmed gone on device.
            let t0 = Date()
            Haptics.impact(.light)
            let tHaptic = Date()
            setMenu(true)
            let t1 = Date()
            diagLog(String(format: "trackActions tap: haptic=%.0fms setMenu=%.0fms",
                           tHaptic.timeIntervalSince(t0) * 1000,
                           t1.timeIntervalSince(tHaptic) * 1000))
            TrackActionsSheet.tapAt = t0
            // The menu's Album and Artist rows are a track-anchored resolve
            // that used to start cold on the tap. Opening the menu is the
            // intent signal, so start them now; by the time a row is chosen
            // (and the 0.35s dismiss beat has run) they are usually done.
            // Utility priority and fire-and-forget: the menu's own
            // presentation must never wait on it.
            let song = song
            Task(priority: .utility) {
                await CatalogPrefetch.pending(song: song, playerVM: playerVM, service: musicService)
            }
        } label: {
            Image(systemName: Icons.moreActions)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint ?? Color.nodalong.textOnAccent.opacity(0.85))
                .frame(width: 32, height: 32)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        // Warm the Taptic Engine while the button is merely on screen, so the
        // first press never pays the spin-up. `prepare()` doesn't block.
        .onAppear { Haptics.prepare(.light) }
        // A bare transparent cover, NOT a sheet: on iOS 26 a sheet's Liquid
        // Glass container is drawn outside what `presentationBackground`
        // reaches, so our card ended up nested inside a system material.
        .fullScreenCover(isPresented: $showMenu) {
            TrackActionsSheet(song: song, onAddToQueue: onAddToQueue, showsTasteActions: showsTasteActions, onSelect: handle)
                .presentationBackground(.clear)
        }
        .sheet(isPresented: $showPlaylistPicker) {
            AddToPlaylistSheet(song: song)
        }
        .sheet(isPresented: $showSendSheet) {
            SendSongSheet(song: song)
        }
    }

    /// Every branch closes the menu first. The playlist picker is a second
    /// sheet on this same view and can't be presented while the menu is still
    /// up; a push has to leave the modal stack entirely before it can reach
    /// the tab's own navigation. Both therefore wait the same 0.35s dismiss
    /// beat this codebase already uses for exactly that
    /// (`AppRouter.dismissThenPush`, and the Queue→Party cover swap before it).
    private func handle(_ action: TrackActionsSheet.Action) {
        // The sheet has already animated itself out by the time this runs.
        setMenu(false)
        switch action {
        case .dismiss:
            break

        case .addToPlaylist:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { showPlaylistPicker = true }

        case .sendToFriend:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { showSendSheet = true }

        // `dismiss: {}` because `showMenu = false` above already did it —
        // `dismissThenPush` is reused here purely for its captured-tab plus
        // delayed-push behaviour. Both marker types are already registered on
        // every tab's stack, so this needs no new `.navigationDestination`.
        case .openAlbum:
            router.dismissThenPush(
                PendingAlbumResolve(
                    albumName: song.album,
                    artist:    song.artist,
                    artwork:   song.artwork,
                    catalogId: song.catalogId,
                    isrc:      song.isrc,
                    uri:       song.uri,
                    trackTitle: song.title
                ),
                identity: .album(name: song.album, artist: song.artist),
                dismiss: {}
            )

        case .openArtist:
            router.dismissThenPush(
                PendingArtistResolve(
                    trackTitle: song.title,
                    artist:     song.artist,
                    catalogId:  song.catalogId,
                    isrc:       song.isrc,
                    uri:        song.uri
                ),
                identity: .artist(name: song.artist),
                dismiss: {}
            )
        }
    }
}

#if DEBUG
#Preview {
    TrackActionsMenuButton(song: PreviewFixtures.song, onAddToQueue: {})
        .padding()
        .background(Color.nodalong.bgCard)
        .withPreviewEnvironment()
}
#endif
