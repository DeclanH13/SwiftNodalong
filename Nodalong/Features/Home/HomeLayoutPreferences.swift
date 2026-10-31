import Foundation
import NodalongKit

/// The user's own pin/hide choices for Home's sections.
///
/// Deliberately `UserDefaults`, not Firestore. This is a device-local
/// presentation preference — the same class of thing as `AppearanceMode` and
/// `AlbumArtworkStyle`, both of which already live in `UserDefaults` — not
/// app data worth a network write and a profile refresh every time someone
/// taps "hide". The cost of it not following you to a second device is that
/// you re-hide a section once; the cost of doing it properly in Firestore is
/// a write on every toggle plus a new field on `UserProfile`.
///
/// Keyed per-uid so signing into a different account on the same device
/// doesn't inherit the previous user's layout. `load(uid:)` is idempotent and
/// guarded, mirroring `LibraryViewModel.loadedForUid` — safe to call from
/// Home's `.task` on every appearance.
@MainActor
final class HomeLayoutPreferences: ObservableObject {
    /// Sections the user pinned, in the order they should appear.
    @Published private(set) var pinned: [HomeSectionID] = []
    /// Sections the user hid. `orderHomeSections` ignores this for any
    /// section whose `isHideable` is false, so a stale entry can never
    /// strand Home without its fallback content.
    @Published private(set) var hidden: Set<HomeSectionID> = []

    private var loadedForUid: String?

    private func pinnedKey(_ uid: String) -> String { "nodalong.home.pinned.\(uid)" }
    private func hiddenKey(_ uid: String) -> String { "nodalong.home.hidden.\(uid)" }

    func load(uid: String) {
        guard loadedForUid != uid else { return }
        loadedForUid = uid
        let defaults = UserDefaults.standard
        pinned = decodeSectionIDs(defaults.data(forKey: pinnedKey(uid)))
        hidden = Set(decodeSectionIDs(defaults.data(forKey: hiddenKey(uid))))
    }

    // MARK: - Mutations

    func togglePin(_ id: HomeSectionID) {
        if let existing = pinned.firstIndex(of: id) {
            pinned.remove(at: existing)
        } else {
            // Newest pin goes to the top — the tap means "I want this first",
            // not "I want this after my other pins".
            pinned.insert(id, at: 0)
            hidden.remove(id)
        }
        persist()
    }

    func setHidden(_ id: HomeSectionID, _ isHidden: Bool) {
        guard id.isHideable else { return }
        if isHidden {
            hidden.insert(id)
            pinned.removeAll { $0 == id }
        } else {
            hidden.remove(id)
        }
        persist()
    }

    func isPinned(_ id: HomeSectionID) -> Bool { pinned.contains(id) }
    func isHidden(_ id: HomeSectionID) -> Bool { hidden.contains(id) }

    func resetAll() {
        pinned = []
        hidden = []
        persist()
    }

    // MARK: - Storage

    private func persist() {
        guard let uid = loadedForUid else { return }
        let defaults = UserDefaults.standard
        defaults.set(try? JSONEncoder().encode(pinned), forKey: pinnedKey(uid))
        defaults.set(try? JSONEncoder().encode(Array(hidden)), forKey: hiddenKey(uid))
    }

    /// Decodes stored section ids ELEMENT-WISE, dropping any that no longer
    /// exist rather than failing the whole array.
    ///
    /// 🔴 This used to decode `[HomeSectionID]` in one go with `try?`, and the
    /// comment called that "tolerant by design" — it wasn't. `Decodable` fails
    /// an array if a SINGLE element fails, so retiring one section reset every
    /// pin AND un-hid everything the user had hidden. Going via `[String]`
    /// first makes a retired id cost only itself, which is what the original
    /// intent actually required. Valid because `HomeSectionID` is a `String`
    /// raw enum and therefore encodes as a plain array of strings.
    private func decodeSectionIDs(_ data: Data?) -> [HomeSectionID] {
        guard let data,
              let raw = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return raw.compactMap(HomeSectionID.init(rawValue:))
    }
}

#if DEBUG
extension HomeLayoutPreferences {
    static var mockPreview: HomeLayoutPreferences { HomeLayoutPreferences() }
}
#endif
