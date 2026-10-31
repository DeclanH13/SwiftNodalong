import ActivityKit
import SwiftUI
import WidgetKit

/// Lock-screen banner + Dynamic Island for a tune-in / listening-party session.
/// Widgets can't fetch remote images, so there is no artwork — the Nodalong
/// glyph stands in.
struct ListeningLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ListeningActivityAttributes.self) { context in
            LockScreenView(label: context.attributes.label, state: context.state)
                .activityBackgroundTint(Color(red: 0.24, green: 0.18, blue: 0.30))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.title3)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(context.state.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(context.attributes.label).font(.caption2).foregroundStyle(.secondary)
                        ProgressRow(state: context.state)
                    }
                }
            } compactLeading: {
                Image(systemName: "dot.radiowaves.left.and.right")
            } compactTrailing: {
                Image(systemName: context.state.isPlaying ? "waveform" : "pause.fill")
            } minimal: {
                Image(systemName: "dot.radiowaves.left.and.right")
            }
        }
    }
}

private struct LockScreenView: View {
    let label: String
    let state: ListeningActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "dot.radiowaves.left.and.right")
                Text(label).font(.caption.weight(.semibold))
            }
            .foregroundStyle(.white.opacity(0.8))
            Text(state.title).font(.headline).lineLimit(1)
            Text(state.artist).font(.subheadline).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
            ProgressRow(state: state)
        }
        .foregroundStyle(.white)
        .padding(16)
    }
}

private struct ProgressRow: View {
    let state: ListeningActivityAttributes.ContentState

    var body: some View {
        if state.isPlaying, let start = state.progressStart, let end = state.progressEnd, end > start {
            ProgressView(timerInterval: start...end, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                .tint(.white)
        } else {
            Label(state.isPlaying ? "Playing" : "Paused", systemImage: state.isPlaying ? "waveform" : "pause.fill")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
        }
    }
}
