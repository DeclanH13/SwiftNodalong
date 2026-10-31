import Foundation

/// The playback queue as a value: every track in order plus which one is
/// current. Phase 1 of the queue-manager plan — `PlayerViewModel` will route
/// every queue change through `reduceQueue(_:_:)` so there is exactly one place
/// the queue's order, membership and current track can change.
///
/// The current track is held by `QueueItem.id`, not by index. An index goes
/// stale the moment anything before it is inserted or removed; an id can't, so
/// an edit computed against an older view of the queue either finds the item it
/// meant or does nothing — it never hits a neighbour by accident.
public struct QueueState: Equatable, Codable, Sendable {
    public private(set) var items: [QueueItem]
    public private(set) var currentID: UUID?
    /// Bumped by every change to what should be playing or what comes after it.
    /// Async work started against an older epoch (a track load, a native-queue
    /// mirror) compares against this and drops itself instead of acting on a
    /// queue the user has already changed.
    public private(set) var epoch: UInt64

    public init() {
        items = []
        currentID = nil
        epoch = 0
    }

    /// A queue with `currentIndex` clamped into range — used to restore a
    /// persisted queue, whose stored index may not match its items.
    public init(items: [QueueItem], currentIndex: Int) {
        self.items = items
        self.currentID = items.isEmpty ? nil : items[min(max(0, currentIndex), items.count - 1)].id
        self.epoch = 0
    }

    public var currentIndex: Int? {
        guard let currentID else { return nil }
        return items.firstIndex { $0.id == currentID }
    }
    public var current: QueueItem? { currentIndex.map { items[$0] } }
    /// Tracks after the current one — what Up Next shows.
    public var upNext: ArraySlice<QueueItem> {
        guard let i = currentIndex else { return [] }
        return items[(i + 1)...]
    }
    /// Tracks before the current one — what ⏮ steps back through.
    public var history: ArraySlice<QueueItem> {
        guard let i = currentIndex else { return [] }
        return items[..<i]
    }
    public var hasNext: Bool { !upNext.isEmpty }
    public var hasPrevious: Bool { !history.isEmpty }

    fileprivate mutating func setCurrent(_ id: UUID?) {
        currentID = id
        epoch &+= 1
    }

    fileprivate mutating func setItems(_ new: [QueueItem]) {
        items = new
        epoch &+= 1
    }
}

/// Every way the queue can change.
public enum QueueCommand: Equatable, Sendable {
    /// Replace the whole queue and start at `startAt`. Tapping a song in an album,
    /// playlist or search result does this on purpose (single song = `[song]`, 0).
    case replace([Song], startAt: Int)
    /// Add to the end. `startIfIdle`: nothing is playing (empty queue, or the
    /// last track finished), so the added track should start rather than wait.
    case append(Song, startIfIdle: Bool)
    /// Insert straight after the current track ("Play next"). Same `startIfIdle`.
    case insertNext(Song, startIfIdle: Bool)
    /// Move Up Next items so they sit before `before` (nil = the end of Up Next).
    /// Ids that are no longer in Up Next are ignored.
    case move(ids: [UUID], before: UUID?)
    /// Remove Up Next items. The current track is never removed.
    case remove(ids: Set<UUID>)
    case clearUpNext
    case next
    /// `restartInstead`: the caller decided ⏮ should restart the current track
    /// (more than a few seconds in). Also restarts when there is no history.
    case previous(restartInstead: Bool)
    /// Jump to an item already in the queue (tapping an Up Next row).
    case jump(UUID)
    /// The track `itemID` finished. Ignored if something else is current by now —
    /// a skip already moved on, so advancing again would skip twice.
    case trackEnded(itemID: UUID)
    /// `itemID` couldn't be resolved or played; move past it. Ignored if it is no
    /// longer current.
    case skipUnplayable(itemID: UUID)
    /// MusicKit moved on its own (natural end, Control Center next/previous) onto
    /// the entry the caller identified as `toItemID`. nil = an entry that isn't in
    /// our queue at all (one we removed or cleared after mirroring it).
    case nativeMoved(toItemID: UUID?)
    /// A listening-party snapshot (host side): rebuild Up Next to match `songs`
    /// after the current track, keeping the current track and the history.
    /// Matches by `Song.id` (the party queue-doc id).
    case reconcile([Song])
    /// Empty the queue (dismiss, leaving follow mode).
    case clearAll
}

/// What the player has to do as a result of a command. Everything else (publish,
/// persist, native mirror, prefetch) follows from the new state alone.
public enum QueueEffect: Equatable, Sendable {
    case none
    /// Load this item into the player from scratch.
    case load(UUID)
    /// The player is already on this item (MusicKit moved there itself) — update
    /// the now-playing surface only; reloading would restart the track.
    case adopt(UUID)
    /// Seek the current track back to the start.
    case restart
    /// Nothing left to play: stop, keeping the now-playing surface.
    case stop
}

/// The only place the queue changes. Pure, so every rule below is unit-tested.
@discardableResult
public func reduceQueue(_ s: inout QueueState, _ command: QueueCommand) -> QueueEffect {
    switch command {

    case .replace(let songs, let start):
        guard songs.indices.contains(start) else { return .none }
        let items = songs.map { QueueItem(song: $0) }
        s.setItems(items)
        s.setCurrent(items[start].id)
        return .load(items[start].id)

    case .append(let song, let startIfIdle):
        let item = QueueItem(song: song)
        s.setItems(s.items + [item])
        guard s.currentID == nil || startIfIdle else { return .none }
        s.setCurrent(item.id)
        return .load(item.id)

    case .insertNext(let song, let startIfIdle):
        let item = QueueItem(song: song)
        guard let i = s.currentIndex else {
            s.setItems(s.items + [item])
            s.setCurrent(item.id)
            return .load(item.id)
        }
        var items = s.items
        items.insert(item, at: i + 1)
        s.setItems(items)
        guard startIfIdle else { return .none }
        s.setCurrent(item.id)
        return .load(item.id)

    case .move(let ids, let before):
        guard let i = s.currentIndex else { return .none }
        let moving = Set(ids)
        let up = Array(s.items[(i + 1)...])
        let moved = up.filter { moving.contains($0.id) }      // keeps their order
        guard !moved.isEmpty else { return .none }
        var rest = up.filter { !moving.contains($0.id) }
        // Anchor on the first non-moving item at or after `before`, so dropping a
        // selection "before" one of its own members still lands sensibly.
        var at = rest.count
        if let before, let b = up.firstIndex(where: { $0.id == before }) {
            if let anchor = up[b...].first(where: { !moving.contains($0.id) }),
               let r = rest.firstIndex(where: { $0.id == anchor.id }) {
                at = r
            }
        }
        rest.insert(contentsOf: moved, at: at)
        guard rest != up else { return .none }
        s.setItems(Array(s.items[...i]) + rest)
        return .none

    case .remove(let ids):
        guard let i = s.currentIndex else { return .none }
        let up = s.items[(i + 1)...]
        let kept = up.filter { !ids.contains($0.id) }
        guard kept.count != up.count else { return .none }
        s.setItems(Array(s.items[...i]) + kept)
        return .none

    case .clearUpNext:
        guard let i = s.currentIndex, s.hasNext else { return .none }
        s.setItems(Array(s.items[...i]))
        return .none

    case .next:
        guard let i = s.currentIndex else { return .none }
        guard i + 1 < s.items.count else { return .stop }
        let next = s.items[i + 1].id
        s.setCurrent(next)
        return .load(next)

    case .previous(let restartInstead):
        guard let i = s.currentIndex else { return .none }
        guard !restartInstead, i > 0 else { return .restart }
        let previous = s.items[i - 1].id
        s.setCurrent(previous)
        return .load(previous)

    case .jump(let id):
        guard s.items.contains(where: { $0.id == id }) else { return .none }
        s.setCurrent(id)
        return .load(id)

    case .trackEnded(let id), .skipUnplayable(let id):
        guard id == s.currentID else { return .none }
        return reduceQueue(&s, .next)

    case .nativeMoved(let target):
        guard let target, s.items.contains(where: { $0.id == target }) else {
            // MusicKit started something we no longer have: play what we actually
            // want next, or stop if there is nothing.
            guard let next = s.upNext.first else { return .stop }
            s.setCurrent(next.id)
            return .load(next.id)
        }
        guard target != s.currentID else { return .none }
        s.setCurrent(target)
        return .adopt(target)

    case .reconcile(let songs):
        guard let current = s.current,
              let anchor = songs.firstIndex(where: { $0.id == current.song.id }) else { return .none }
        let upcoming = songs[(anchor + 1)...]
        guard upcoming.map(\.id) != s.upNext.map(\.song.id) else { return .none }
        // Reuse existing items (matched by the party doc id) so a row the user is
        // looking at, or dragging, keeps its identity across the update.
        var existing: [String: QueueItem] = [:]
        for item in s.upNext where existing[item.song.id] == nil { existing[item.song.id] = item }
        let newUp = upcoming.map { song -> QueueItem in
            if let item = existing.removeValue(forKey: song.id) { return item }
            return QueueItem(song: song)
        }
        s.setItems(Array(s.history) + [current] + newUp)
        return .none

    case .clearAll:
        guard !s.items.isEmpty else { return .none }
        s.setItems([])
        s.setCurrent(nil)
        return .none
    }
}
