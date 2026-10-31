import SwiftUI
import NodalongKit

/// The "…" menu's contents — our own surface, replacing the system
/// `confirmationDialog` that shipped before it (text-only, no icons, and no
/// way to show the album or artist).
///
/// **Self-sufficient by design.** It takes a `Song` and derives everything
/// else from environment objects it can already reach: liked state from
/// `LibraryViewModel`, spotlight state from `FirebaseAuthViewModel`. The
/// alternative — every call site passing state and closures for all six rows
/// — would have multiplied a `LibraryTrackDoc` construction that four screens
/// were already duplicating inline.
///
/// Presented by `TrackActionsMenuButton` as a **transparent
/// `.fullScreenCover`**, and draws its own scrim, card and transition.
///
/// It started as a `.sheet` with `.presentationBackground(.clear)`, on the
/// assumption that cleared the system surface. On iOS 26 it does not — the
/// sheet's Liquid Glass container is drawn outside what `presentationBackground`
/// reaches, so our card ended up nested inside a system material. A bare
/// transparent cover has no container of its own, which is the only way to make
/// this genuinely our surface.
struct TrackActionsSheet: View {

    /// TEMPORARY [Nodalong.Diag] — when the "…" was tapped, so `onAppear`
    /// can report the full tap→visible cost. Remove with the instrumentation
    /// in `TrackActionsMenuButton`.
    @MainActor static var tapAt: Date?

    /// What the user picked. Reported to the presenter rather than handled
    /// here, because the two navigating cases need the sheet gone *first* —
    /// see `TrackActionsMenuButton.handle(_:)`.
    enum Action { case dismiss, addToPlaylist, sendToFriend, openAlbum, openArtist }

    let song: Song
    /// Personal-queue add. Nil where a screen genuinely has no queue action;
    /// the row hides rather than sitting there doing nothing.
    var onAddToQueue: (() -> Void)? = nil
    var showsTasteActions: Bool = false
    let onSelect: (Action) -> Void

    @EnvironmentObject private var libraryVM: LibraryViewModel
    @EnvironmentObject private var partyVM:   ListeningPartyViewModel
    @EnvironmentObject private var playerVM:  PlayerViewModel
    @EnvironmentObject private var tasteStore: TasteOverridesStore
    @Environment(FirebaseAuthViewModel.self) private var authVM

    /// Minimum row heights. The card sizes to its content now that there is no
    /// detent to pre-compute, so these are floors rather than a budget — a
    /// larger text size grows the row instead of being clipped by it.
    @ScaledMetric private var actionRowHeight: CGFloat = 44
    @ScaledMetric private var navRowHeight:    CGFloat = 52
    @ScaledMetric private var headerHeight:    CGFloat = 56

    /// Drives our own transition. The cover is presented with animations
    /// disabled (see `TrackActionsMenuButton`), so this view owns both the
    /// scrim's fade and the card's slide — otherwise the system slides the
    /// *scrim* up too, which reads as a sheet rather than a dim.
    @State private var shown = false

    // MARK: - Derived state

    private var isLiked: Bool {
        libraryVM.isInLibrary(catalogId: song.catalogId, uri: song.uri)
    }

    private var isSpotlit: Bool { authVM.todaySpotlight(matching: song) != nil }

    /// Only two things disable this: today's daily limit, with this track not
    /// already one of today's picks. A missing `catalogId` is not one of them —
    /// see `FirebaseAuthViewModel.canSpotlight`. Disabling at the cap is also
    /// what makes `spotlightLimitReached`'s alert structurally unreachable from
    /// here, which matters more for this sheet than for most — it also appears
    /// on screens (Search, album detail) that host no such alert at all.
    private var spotlightDisabled: Bool {
        !authVM.canSpotlight(song)
    }

    /// True when a live party this device can add to is active — the queue row
    /// then targets the shared party queue instead of the personal one. Same
    /// routing the `confirmationDialog` did before it.
    private var routeToParty: Bool { partyVM.isActive && partyVM.canAddToQueue }

    private var showsAlbum:  Bool { !song.album.isEmpty }
    private var showsArtist: Bool { !song.artist.isEmpty }

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(shown ? 0.45 : 0)
                .ignoresSafeArea()
                .contentShape(.rect)
                .onTapGesture { close(.dismiss) }

            card
                .padding(.horizontal, 8)
                .padding(.bottom, max(ScreenMetrics.safeAreaInsets.bottom, 8))
                .offset(y: shown ? 0 : 400)
                // Release-triggered, not finger-tracking — a real interactive
                // dismissal would mean driving the offset from the drag and is
                // more than this needs.
                .gesture(
                    DragGesture()
                        .onEnded { if $0.translation.height > 60 { close(.dismiss) } }
                )
        }
        // Pinned to the physical screen with the real window insets re-applied,
        // rather than trusting this cover's own environment — the pattern
        // `NowPlayingView` arrived at after a `safeAreaInset` leaked a phantom
        // inset into its cover. See `ScreenMetrics.safeAreaInsets`.
        .frame(width: ScreenMetrics.bounds.width, height: ScreenMetrics.bounds.height)
        .ignoresSafeArea()
        .onAppear {
            if let tapAt = Self.tapAt {
                diagLog(String(format: "trackActions sheet onAppear: %.0fms after tap",
                               Date().timeIntervalSince(tapAt) * 1000))
                Self.tapAt = nil
            }
            withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { shown = true }
        }
    }

    /// Animates the card out *before* reporting, so it leaves the screen
    /// instead of vanishing with the cover.
    private func close(_ action: Action) {
        withAnimation(.easeIn(duration: 0.18)) { shown = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { onSelect(action) }
    }

    private var card: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.nodalong.textPrimary.opacity(0.3))
                .frame(width: 34, height: 4)
                .padding(.top, 6)
                .padding(.bottom, 8)

            header
            divider

            actionRow(
                icon:  isLiked ? Icons.heart : Icons.heartOutline,
                tint:  isLiked ? Color.nodalong.purpleAccent : nil,
                label: isLiked ? "Remove from Shelf" : "Add to Shelf"
            ) {
                guard let uid = authVM.currentUser?.uid else { return }
                Task { await libraryVM.toggleLibrary(uid: uid, track: .from(song: song)) }
                close(.dismiss)
            }

            actionRow(
                icon:     isSpotlit ? Icons.star : "star",
                tint:     isSpotlit ? Color.nodalong.gold : nil,
                label:    isSpotlit ? "Remove Spotlight" : "Spotlight",
                disabled: spotlightDisabled
            ) {
                Task { await authVM.toggleSpotlight(song) }
                close(.dismiss)
            }

            if routeToParty {
                actionRow(icon: Icons.addToQueue, label: "Add to LP Queue") {
                    partyVM.addToQueue(song)
                    close(.dismiss)
                }
            } else if let onAddToQueue {
                // Only meaningful with something already playing — otherwise
                // "next" and "add" are the same thing.
                if playerVM.nowPlaying != nil, !partyVM.isActive {
                    actionRow(icon: Icons.playNext, label: "Play Next") {
                        playerVM.playNext(song)
                        close(.dismiss)
                    }
                }
                actionRow(icon: Icons.addToQueue, label: "Add to Queue") {
                    onAddToQueue()
                    close(.dismiss)
                }
            }

            actionRow(icon: Icons.musicalNotesOutline, label: "Add to Playlist") {
                close(.addToPlaylist)
            }

            actionRow(icon: "paperplane", label: "Send to a Friend") {
                close(.sendToFriend)
            }

            if showsTasteActions, showsArtist {
                actionRow(icon: "minus.circle", label: "Play less of \(song.artist)") {
                    tasteStore.reduce(song.artist)
                    close(.dismiss)
                }
                actionRow(icon: "nosign", label: "Never suggest \(song.artist)") {
                    tasteStore.block(song.artist)
                    close(.dismiss)
                }
            }

            if showsAlbum || showsArtist { divider }

            if showsAlbum {
                navRow(icon: Icons.discOutline, name: song.album, caption: "Album") {
                    close(.openAlbum)
                }
            }
            if showsArtist {
                navRow(icon: Icons.personOutline, name: song.artist, caption: "Artist") {
                    close(.openArtist)
                }
            }
        }
        .padding(.bottom, 10)
        .background(Color.nodalong.bgElevated)
        .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
        // In dark mode `bgElevated` and `bgCard` are the same value, so a menu
        // opened over a card would otherwise have no visible edge. The sheet's
        // own dimming scrim does most of the separating; this is the backstop.
        .overlay(
            RoundedRectangle(cornerRadius: Corner.container, style: .continuous)
                .strokeBorder(Color.nodalong.textPrimary.opacity(0.14), lineWidth: 0.5)
        )
    }

    // MARK: - Rows

    private var header: some View {
        HStack(spacing: 10) {
            ArtworkThumbnail(url: song.artwork, size: 40)
                .clipShape(RoundedRectangle(cornerRadius: Corner.artwork, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(song.title)
                    .font(Font.nodalong.subheadlineSemibold)
                    .foregroundStyle(Color.nodalong.textPrimary)
                    .lineLimit(1)
                Text(song.artist)
                    .font(Font.nodalong.caption)
                    .foregroundStyle(Color.nodalong.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(height: headerHeight)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.nodalong.textPrimary.opacity(0.14))
            .frame(height: 0.5)
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
    }

    private func actionRow(
        icon: String,
        tint: Color? = nil,
        label: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundStyle(tint ?? Color.nodalong.textPrimary.opacity(0.85))
                    .frame(width: 22)
                Text(label)
                    .font(Font.nodalong.subheadlineMedium)
                    .foregroundStyle(Color.nodalong.textPrimary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(height: actionRowHeight)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
    }

    private func navRow(
        icon: String,
        name: String,
        caption: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundStyle(Color.nodalong.textPrimary.opacity(0.85))
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .font(Font.nodalong.subheadlineMedium)
                        .foregroundStyle(Color.nodalong.textPrimary)
                        .lineLimit(1)
                    Text(caption)
                        .font(Font.nodalong.caption)
                        .foregroundStyle(Color.nodalong.textSecondary)
                }
                Spacer(minLength: 0)
                Image(systemName: Icons.chevronForward)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.nodalong.textTertiary)
            }
            .padding(.horizontal, 16)
            .frame(height: navRowHeight)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

#if DEBUG
#Preview {
    TrackActionsSheet(song: PreviewFixtures.song, onAddToQueue: {}) { _ in }
        .background(Color.nodalong.bgBase)
        .withPreviewEnvironment()
}
#endif
