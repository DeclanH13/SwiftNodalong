import SwiftUI

/// Transient "Added to queue" / "Added to LP queue" / "Skipped" toast
/// pills, shown via `.overlay(alignment: .bottom)` on the root `TabView`.
///
/// Previously this view (`BottomSection`) also hosted `MiniPlayerBar` via a
/// `.safeAreaInset`. The mini player now lives in the system's
/// `.tabViewBottomAccessory` slot instead (see `MainTabView`) — the system
/// manages its position (expanded above the tab bar, or merged inline while
/// scrolling), so this view's own remaining job is the toast pills. Keyboard
/// tracking is still needed here though — not for positioning, but because
/// nothing else paints over the black UIKit layer behind the keyboard once
/// it's up.
struct QueueToastOverlay: View {
    @EnvironmentObject private var playerVM: PlayerViewModel
    @EnvironmentObject private var partyVM:  ListeningPartyViewModel

    /// `true` while any keyboard is on screen (e.g. Shelf's `.searchable`
    /// filter focused). Drives the background fill below — without it, the
    /// region behind/around the keyboard shows the raw black UIKit layer
    /// instead of the app's background, regardless of whether a toast is
    /// currently showing.
    @State private var keyboardVisible = false

    var body: some View {
        VStack(spacing: 0) {
            if let title = partyVM.queueToast {
                queueToastPill(title: title, label: "Added to LP queue", icon: "nodalongMark")
                    .padding(.horizontal, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let title = playerVM.queueToast {
                let skipped = playerVM.queueToastKind == .skipped
                queueToastPill(
                    title: title,
                    label: skipped ? "Skipped (unavailable)" : "Added to queue",
                    icon: skipped ? "forward.end.fill" : Icons.addToQueue
                )
                .padding(.horizontal, 24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        // Approximate clearance above the tab bar / merged-inline mini
        // player — the system manages the accessory's own position, so this
        // is a fixed estimate rather than a measured value. Needs an
        // on-device look to confirm it reads correctly in both the expanded
        // and minimized tab bar states.
        .padding(.bottom, 100)
        // Fills the region with the app background when the keyboard is up
        // so it shows the app colour rather than the black UIKit layer
        // behind the keyboard. Stays clear when the keyboard is hidden.
        .background(keyboardVisible ? Color.nodalong.bgBase : .clear)
        .animation(.spring(response: 0.35, dampingFraction: 0.80), value: playerVM.queueToast != nil)
        .animation(.spring(response: 0.35, dampingFraction: 0.80), value: partyVM.queueToast != nil)
        .animation(.easeInOut(duration: 0.25), value: keyboardVisible)
        .onReceive(
            NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)
        ) { _ in keyboardVisible = true }
        .onReceive(
            NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)
        ) { _ in keyboardVisible = false }
    }

    @ViewBuilder
    private func queueToastPill(title: String, label: String, icon: String) -> some View {
        HStack(spacing: 8) {
            // "nodalongMark" is the brand mark (a bundled template asset, not
            // an SF Symbol) — used for the LP-queue toast specifically, so
            // it reads as "added to the LP" rather than a generic queue icon.
            // Every other caller still passes a real SF Symbol name.
            Group {
                if icon == "nodalongMark" {
                    NodalongMark(size: 14)
                } else {
                    Image(systemName: icon)
                }
            }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.nodalong.purpleAccent)
            Text(label)
                .font(Font.nodalong.custom(13, .semibold))
                .foregroundStyle(Color.nodalong.textPrimary)
            Text("· \(title)")
                .font(Font.nodalong.custom(13))
                .foregroundStyle(Color.nodalong.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .background(Color.nodalong.bgCard.opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
    }
}

#if DEBUG
#Preview {
    QueueToastOverlay().withPreviewEnvironment()
}
#endif
