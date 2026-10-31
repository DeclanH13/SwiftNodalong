import Foundation

/// What the home/lock-screen widgets show. The app writes this into the App
/// Group container; the widgets only ever read it (they can't reach Firebase or
/// MusicKit, and can't fetch images, so artwork is pre-downloaded alongside).
///
/// Every field is optional/defaulted so a payload written by an older or newer
/// build still decodes — a failed decode would silently blank the widget.
struct WidgetPayload: Codable, Equatable {
    struct Spotlight: Codable, Equatable, Identifiable {
        var id: String
        var username: String
        var title: String
        var artist: String
        var artworkFile: String?
    }
    struct NowPlaying: Codable, Equatable {
        var title: String
        var artist: String
        var isPlaying: Bool
        var artworkFile: String?
    }

    var spotlights: [Spotlight]? = nil
    var nowPlaying: NowPlaying? = nil
    var updatedAt: Date? = nil
}

enum WidgetStore {
    static let appGroup = "group.com.bigdeccyh.nodalong"

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }

    private static var payloadURL: URL? { containerURL?.appendingPathComponent("widget.json") }

    static func read() -> WidgetPayload {
        guard let url = payloadURL, let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(WidgetPayload.self, from: data) else { return WidgetPayload() }
        return payload
    }

    static func write(_ payload: WidgetPayload) {
        guard let url = payloadURL, let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func artworkURL(file: String?) -> URL? {
        guard let file, let dir = containerURL else { return nil }
        return dir.appendingPathComponent(file)
    }
}
