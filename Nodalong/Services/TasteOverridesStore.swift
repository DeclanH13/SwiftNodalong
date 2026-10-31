import SwiftUI
import NodalongKit

/// Holds the user's artist overrides ("play less" / "never suggest") and
/// persists them per account in `UserDefaults` — device-local by choice: no
/// rules change, nothing other users can read. Lost on reinstall or a new phone.
@MainActor
final class TasteOverridesStore: ObservableObject {
    @Published private(set) var overrides = TasteOverrides()
    private var uid: String?

    nonisolated private static func key(_ uid: String) -> String { "nodalong.tasteOverrides.\(uid)" }

    /// Synchronous read for non-UI callers (the playlist generator), so they
    /// don't need the store injected.
    nonisolated static func load(uid: String) -> TasteOverrides {
        guard let data = UserDefaults.standard.data(forKey: key(uid)),
              let decoded = try? JSONDecoder().decode(TasteOverrides.self, from: data) else { return TasteOverrides() }
        return decoded
    }

    func start(uid: String) {
        guard self.uid != uid else { return }
        self.uid = uid
        overrides = Self.load(uid: uid)
    }

    func stop() { uid = nil; overrides = TasteOverrides() }

    func block(_ artist: String)  { mutate { $0.block(artist) } }
    func reduce(_ artist: String) { mutate { $0.reduce(artist) } }
    func clear(key: String)       { mutate { $0.clear(key: key) } }

    private func mutate(_ change: (inout TasteOverrides) -> Void) {
        guard let uid else { return }
        var next = overrides
        change(&next)
        overrides = next
        if let data = try? JSONEncoder().encode(next) { UserDefaults.standard.set(data, forKey: Self.key(uid)) }
    }
}

#if DEBUG
extension TasteOverridesStore {
    static var mockPreview: TasteOverridesStore { TasteOverridesStore() }
}
#endif
