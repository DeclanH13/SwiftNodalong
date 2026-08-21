/// A followed user who's currently live — either hosting a listening party
/// or just playing something solo. Powers Home's "Live Now" section, which
/// is follows-only and hidden entirely when nobody's live.
public struct LiveNowEntry: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case hostingParty(ListeningParty)
        case listening(catalogId: String)
    }

    /// The uid — stable across a load, not a persistent app-wide identifier.
    public let id: String
    public let uid: String
    public let username: String
    public let avatarEmoji: String?
    public let avatarColor: String?
    public let kind: Kind

    public init(uid: String, username: String, avatarEmoji: String?, avatarColor: String?, kind: Kind) {
        self.id = uid
        self.uid = uid
        self.username = username
        self.avatarEmoji = avatarEmoji
        self.avatarColor = avatarColor
        self.kind = kind
    }
}
