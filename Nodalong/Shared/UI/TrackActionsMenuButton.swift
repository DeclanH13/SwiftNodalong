import SwiftUI
import NodalongKit

/// Visible "..." button hosting every available track action for the row/card
/// it's attached to. Replaces the old long-press menu (`QueueContextMenu`,
/// removed) — that affordance was undiscoverable, with no visual cue it
/// existed.
///
/// Adaptive by construction: pass only the actions that are actually
/// available for this context. `onToggleLike`/`onSpotlight` are omitted
/// (`nil`) wherever a screen already shows those as separate visible icons
/// (e.g. `TrackCard`), and included where the row has no room to show them
/// separately (Search/Shelf/Album/Artist/Playlist rows).
///
/// **Party routing:** when a listening party this device can add to is
/// active, the queue action swaps from the personal player queue to the
/// shared party queue — same trigger, same position in the dialog, different
/// destination and label. Mirrors the exact behavior `QueueContextMenu` had.
struct TrackActionsMenuButton: View {
    var song: Song? = nil
    var onAddToQueue: (() -> Void)? = nil
    var onToggleLike: (() -> Void)? = nil
    var isLiked: Bool = false
    var onSpotlight: (() -> Void)? = nil
    var isSpotlit: Bool = false

    @EnvironmentObject private var partyVM: ListeningPartyViewModel
    @State private var showDialog = false
    @State private var showPlaylistPicker = false

    /// True when a live party this device can add to is active AND a `Song`
    /// is available to add — the condition for routing to the party queue
    /// instead of the personal one.
    private var routeToParty: Bool {
        partyVM.isActive && partyVM.canAddToQueue && song != nil
    }

    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            showDialog = true
        } label: {
            Image(systemName: Icons.moreActions)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.nodalong.textOnAccent.opacity(0.85))
                .frame(width: 32, height: 32)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .confirmationDialog("", isPresented: $showDialog, titleVisibility: .hidden) {
            if let onToggleLike {
                Button(isLiked ? "Remove from Shelf" : "Add to Shelf") { onToggleLike() }
            }
            if let onSpotlight {
                Button(isSpotlit ? "Remove Spotlight" : "Spotlight") { onSpotlight() }
            }
            if routeToParty, let song {
                Button("Add to LP Queue") { partyVM.addToQueue(song) }
            } else if let onAddToQueue {
                Button("Add to Queue") { onAddToQueue() }
            }
            if song != nil { Button("Add to Playlist…") { showPlaylistPicker = true } }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showPlaylistPicker) {
            if let song { AddToPlaylistSheet(song: song) }
        }
    }
}

#if DEBUG
#Preview {
    TrackActionsMenuButton(
        song: PreviewFixtures.song,
        onAddToQueue: {},
        onToggleLike: {},
        isLiked: true
    )
    .padding()
    .background(Color.nodalong.bgCard)
    .withPreviewEnvironment()
}
#endif
