import SwiftUI
import FirebaseFirestore
import NodalongKit

/// Owns the inbox listener and the unread badge. Started once from
/// `MainTabView`; the watermark lives in `UserDefaults` per uid (device-local —
/// opening the inbox on one device doesn't clear the badge on another, an
/// accepted v1 simplification).
@MainActor
final class InboxViewModel: ObservableObject {
    @Published private(set) var items: [InboxItem] = []
    @Published private(set) var seenAtMs: Double = 0

    private var listener: ListenerRegistration?
    private var uid: String?

    var unreadCount: Int { unreadInboxCount(items: items, seenAtMs: seenAtMs) }

    init() {}

    func start(uid: String) {
        guard self.uid != uid else { return }
        stop()
        self.uid = uid
        if ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" { return }
        seenAtMs = UserDefaults.standard.double(forKey: Self.seenKey(uid))
        listener = listenToInbox(uid: uid) { [weak self] items in
            Task { @MainActor in self?.items = items }
        }
    }

    func stop() {
        listener?.remove(); listener = nil
        uid = nil; items = []
    }

    /// Called when the inbox screen opens.
    func markSeen() {
        guard let uid else { return }
        let now = Date().timeIntervalSince1970 * 1000
        seenAtMs = now
        UserDefaults.standard.set(now, forKey: Self.seenKey(uid))
    }

    func dismiss(_ item: InboxItem) {
        guard let uid else { return }
        items.removeAll { $0.id == item.id }
        Task { await deleteInboxItem(uid: uid, itemId: item.id) }
    }

    private static func seenKey(_ uid: String) -> String { "nodalong.inboxSeenAt.\(uid)" }
}

#if DEBUG
extension InboxViewModel {
    static var mockPreview: InboxViewModel { InboxViewModel() }
}
#endif
