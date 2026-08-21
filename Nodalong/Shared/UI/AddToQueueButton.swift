import SwiftUI
import NodalongKit

/// Visible "add to queue" icon, routed exactly like `TrackActionsMenuButton`'s
/// own queue action.
///
/// **The routing is the whole point.** `TrackCard` previously had a standalone
/// icon that called `onAddToQueue` directly, which silently added to the
/// PERSONAL queue even while a listening party was active — confirmed on
/// device, and the reason that button was removed rather than fixed in place
/// at the time. This exists so the action can be surfaced as a one-tap icon
/// again *without* reintroducing that bug: when a party this device may add to
/// is live, it goes to the shared LP queue instead, same condition and same
/// destination as the "..." menu.
struct AddToQueueButton: View {
    /// Needed for party routing — the LP queue takes a `Song`, not a closure.
    /// Without one, this always falls back to the personal queue.
    var song: Song?
    var onAddToQueue: (() -> Void)?
    /// Cards over artwork need a light glyph plus a shadow to stay legible;
    /// list rows on a solid surface don't.
    var overArtwork: Bool = false

    @EnvironmentObject private var partyVM: ListeningPartyViewModel

    private var routeToParty: Bool {
        partyVM.isActive && partyVM.canAddToQueue && song != nil
    }

    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            if routeToParty, let song {
                partyVM.addToQueue(song)
            } else {
                onAddToQueue?()
            }
        } label: {
            Image(systemName: Icons.addToQueue)
                .font(.system(size: overArtwork ? 22 : 18))
                .foregroundStyle(
                    routeToParty
                        ? Color.nodalong.purpleAccent
                        : (overArtwork
                            ? Color.nodalong.textOnAccent.opacity(0.85)
                            : Color.nodalong.textSecondary)
                )
                .shadow(color: .black.opacity(overArtwork ? 0.7 : 0), radius: 4, y: 1)
                .frame(width: 32, height: 32)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(routeToParty ? "Add to LP queue" : "Add to queue")
    }
}

#if DEBUG
#Preview {
    HStack(spacing: 20) {
        AddToQueueButton(song: PreviewFixtures.song, onAddToQueue: {})
        AddToQueueButton(song: PreviewFixtures.song, onAddToQueue: {}, overArtwork: true)
            .padding()
            .background(Color.black)
    }
    .padding()
    .background(Color.nodalong.bgCard)
    .withPreviewEnvironment()
}
#endif
