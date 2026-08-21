import Foundation

/// Generic JSON snapshot persistence for stale-while-revalidate rendering.
///
/// Cold launch, Home, and Feed all used to render nothing until their first
/// network round trip landed. `SnapshotStore` lets a view model write its
/// last-known-good data to disk after each successful load, and read it back
/// synchronously at (re)launch so the first frame shows real content instead
/// of a spinner — a network refresh then replaces it silently.
///
/// File-based (not `UserDefaults`) because some payloads — Feed's ~50 posts,
/// Home's six arrays — are larger than comfortable for `UserDefaults`. One
/// directory per uid so account switches can never leak content between
/// users, and sign-out can wipe everything for that uid in a single call.
enum SnapshotStore {
    private static func directory(uid: String) -> URL? {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return nil }
        return base.appendingPathComponent("Snapshots/\(uid)", isDirectory: true)
    }

    private static func fileURL(key: String, uid: String) -> URL? {
        guard let dir = directory(uid: uid) else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(key).json")
    }

    /// Synchronous by design — called once at init/first-load so the caller
    /// can populate its published state before the first render. Payloads
    /// here are small enough (at most a few hundred KB) that this is cheap.
    static func load<T: Decodable>(_ type: T.Type, key: String, uid: String) -> T? {
        guard let url = fileURL(key: key, uid: uid),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// Fire-and-forget — encodes and writes off the main thread so a save
    /// never blocks the caller. Best-effort: a failed write just means the
    /// next launch falls back to the network, same as today.
    static func save<T: Encodable & Sendable>(_ value: T, key: String, uid: String) {
        guard let url = fileURL(key: key, uid: uid) else { return }
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(value) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Removes every snapshot for `uid` — called on sign-out so a later
    /// sign-in (same device, different account) can never render a stale
    /// snapshot belonging to someone else.
    static func clear(uid: String) {
        guard let dir = directory(uid: uid) else { return }
        try? FileManager.default.removeItem(at: dir)
    }
}
