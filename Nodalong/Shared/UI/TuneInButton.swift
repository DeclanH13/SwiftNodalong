import SwiftUI
import NodalongKit

/// "Tune In" — play the same track on this device, aligned to another user's
/// position (single-song). Requires an Apple Music subscription on BOTH sides:
/// this device (each device streams the full track) and the broadcaster (a
/// preview-mode broadcaster's own playback cycles every ~30s, which sync would
/// just follow into a broken cycling loop). Shared by NearMe, profiles and Home.
struct TuneInButton: View {
    let uid: String
    let username: String
    /// Whether the broadcaster is currently on 30-second previews.
    let isPreviewPlayback: Bool
    /// Compact style (icon + label pill) for tight rows like Home's Live Now rail.
    var compact: Bool = false
    var onTuned: () -> Void = {}

    @EnvironmentObject private var musicService: AppleMusicService
    @EnvironmentObject private var syncCoordinator: SyncFollowCoordinator

    var body: some View {
        if !musicService.canPlayFullTracks {
            if !compact { note("Apple Music subscription required to tune in") }
        } else if isPreviewPlayback {
            if !compact { note("Sync unavailable — \(username) isn't on Apple Music") }
        } else {
            Button {
                syncCoordinator.tuneIn(uid: uid, label: "Tuned in to \(username)")
                onTuned()
            } label: {
                HStack(spacing: compact ? 4 : 8) {
                    NodalongMark(size: compact ? 12 : 18)
                    Text("Tune In").font(compact ? Font.nodalong.captionBold : Font.nodalong.subheadlineSemibold)
                    if !compact { Spacer() }
                }
                .foregroundStyle(Color.nodalong.textOnAccent)
                .padding(.horizontal, compact ? 8 : 14).padding(.vertical, compact ? 4 : 9)
                .background(Color.nodalong.purpleAccent)
                .clipShape(RoundedRectangle(cornerRadius: compact ? 10 : Corner.container, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(Font.nodalong.caption)
            .foregroundStyle(Color.nodalong.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
