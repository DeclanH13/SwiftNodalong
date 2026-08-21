/// One titled shelf from Apple Music's personal recommendations (e.g. "New
/// Music Mix", "Chill Mix") — v1 surfaces the album collection only, see
/// `AppleMusicService.getPersonalRecommendations`.
public struct RecommendationShelf: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    public let title: String
    public let albums: [AlbumResult]

    public init(id: String, title: String, albums: [AlbumResult]) {
        self.id = id
        self.title = title
        self.albums = albums
    }
}
