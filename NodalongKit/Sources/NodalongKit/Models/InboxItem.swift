import Foundation

/// One entry in a user's inbox: a song a friend sent them, or an invite to a
/// collaborative playlist. Stored at `users/{recipientUid}/inbox/{id}`.
///
/// Decoded tolerantly — an unknown `type` from a newer build becomes `.unknown`
/// instead of failing the whole list.
public struct InboxItem: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable {
        case song, playlistInvite, unknown
    }

    public let id: String
    public let kind: Kind
    public let fromUid: String
    public let fromUsername: String
    public let fromAvatarEmoji: String?
    public let fromAvatarColor: String?
    public let catalogId: String?
    public let playlistId: String?
    public let playlistTitle: String?
    public let note: String?
    public let createdAt: Double

    public init(id: String, kind: Kind, fromUid: String, fromUsername: String,
                fromAvatarEmoji: String? = nil, fromAvatarColor: String? = nil,
                catalogId: String? = nil, playlistId: String? = nil, playlistTitle: String? = nil,
                note: String? = nil, createdAt: Double) {
        self.id = id; self.kind = kind; self.fromUid = fromUid; self.fromUsername = fromUsername
        self.fromAvatarEmoji = fromAvatarEmoji; self.fromAvatarColor = fromAvatarColor
        self.catalogId = catalogId; self.playlistId = playlistId; self.playlistTitle = playlistTitle
        self.note = note; self.createdAt = createdAt
    }

    /// Builds an item from a raw Firestore document; `nil` when the essentials are missing.
    public init?(id: String, data: [String: Any]) {
        guard let fromUid = data["fromUid"] as? String, !fromUid.isEmpty else { return nil }
        self.init(
            id: id,
            kind: Kind(rawValue: data["type"] as? String ?? "") ?? .unknown,
            fromUid: fromUid,
            fromUsername: data["fromUsername"] as? String ?? "",
            fromAvatarEmoji: data["fromAvatarEmoji"] as? String,
            fromAvatarColor: data["fromAvatarColor"] as? String,
            catalogId: data["catalogId"] as? String,
            playlistId: data["playlistId"] as? String,
            playlistTitle: data["playlistTitle"] as? String,
            note: data["note"] as? String,
            createdAt: data["createdAt"] as? Double ?? 0
        )
    }
}

/// Items newer than the last time the user opened the inbox. Unknown kinds are
/// not counted — a row we can't render shouldn't light the badge.
public func unreadInboxCount(items: [InboxItem], seenAtMs: Double) -> Int {
    items.filter { $0.kind != .unknown && $0.createdAt > seenAtMs }.count
}

public let inboxNoteMaxLength = 140
