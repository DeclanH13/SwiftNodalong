import SwiftUI
import NodalongKit

/// "Up Next" queue, presented as a sheet from `NowPlayingView`.
///
/// Two sections:
///   - **Now Playing** — the current entry (not movable / removable).
///   - **Up Next** — `playerVM.upNext`, with drag-to-reorder (`EditButton`),
///     swipe-to-delete, and tap-to-jump.
///
/// All mutations go through `PlayerViewModel`, which owns the queue array; this
/// view never touches the player directly.
struct QueueView: View {
    @EnvironmentObject private var playerVM: PlayerViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.nodalong.bgBase.ignoresSafeArea()
                queueList
            }
            .navigationTitle("Queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !playerVM.upNext.isEmpty {
                        EditButton().tint(Color.nodalong.purpleAccent)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .tint(Color.nodalong.purpleAccent)
                }
            }
        }
    }

    private var queueList: some View {
        List {
            if let current = playerVM.currentItem {
                Section {
                    QueueRow(song: current.song, isCurrent: true)
                        .listRowBackground(Color.nodalong.bgCard)
                } header: {
                    sectionHeader("Now Playing")
                }
            }

            Section {
                if playerVM.upNext.isEmpty {
                    Text("Nothing queued. Swipe a track left to add it to the queue.")
                        .font(Font.nodalong.subheadline)
                        .foregroundStyle(Color.nodalong.textSecondary)
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(playerVM.upNext) { item in
                        Button {
                            Task { await playerVM.playQueueItem(item) }
                        } label: {
                            QueueRow(song: item.song, isCurrent: false)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.nodalong.bgCard)
                    }
                    .onMove(perform: playerVM.moveUpNext)
                    .onDelete(perform: playerVM.removeUpNext)
                }
            } header: {
                sectionHeader("Up Next")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(Font.nodalong.footnoteSemibold)
            .foregroundStyle(Color.nodalong.textSecondary)
    }
}

/// A single queue row — artwork, title/artist, and a speaker glyph on the
/// currently-playing entry.
private struct QueueRow: View {
    let song: Song
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 12) {
            ArtworkThumbnail(url: song.artwork, size: 48, isTrack: true)

            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(Font.nodalong.subheadlineMedium)
                    .foregroundStyle(Color.nodalong.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(song.artist)
                    .font(Font.nodalong.caption)
                    .foregroundStyle(Color.nodalong.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 8)

            if isCurrent {
                Image(systemName: "speaker.wave.2.fill")
                    .font(Font.nodalong.caption)
                    .foregroundStyle(Color.nodalong.purpleAccent)
            }
        }
        .padding(.vertical, 2)
    }
}

#if DEBUG
#Preview {
    QueueView()
        .environmentObject(PlayerViewModel.mockPreviewWithQueue)
}
#endif
