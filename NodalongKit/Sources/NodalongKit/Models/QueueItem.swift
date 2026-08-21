import Foundation

/// A single entry in the playback queue.
///
/// Wraps a `Song` with a stable per-entry `id` so the same track can appear in
/// the queue more than once (a `Song.id` is shared by every surface that
/// references that track, so it can't identify a queue *position*). The UUID is
/// what SwiftUI's `ForEach` / `.onMove` / `.onDelete` key off in the Up Next
/// list, and what `PlayerViewModel.playQueueItem(_:)` matches to jump.
public struct QueueItem: Identifiable, Equatable, Sendable, Codable {
    public let id: UUID
    public let song: Song

    public init(song: Song) {
        self.id = UUID()
        self.song = song
    }
}
