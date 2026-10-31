import SwiftUI
import WidgetKit

struct PayloadEntry: TimelineEntry {
    let date: Date
    let payload: WidgetPayload
}

/// The app pushes updates (`WidgetCenter.reloadAllTimelines`), so the provider
/// has nothing to schedule: it just re-reads the shared file.
struct PayloadProvider: TimelineProvider {
    func placeholder(in context: Context) -> PayloadEntry {
        PayloadEntry(date: .now, payload: WidgetPayload(
            spotlights: [.init(id: "1", username: "friend", title: "Song title", artist: "Artist")],
            nowPlaying: .init(title: "Song title", artist: "Artist", isPlaying: true)))
    }
    func getSnapshot(in context: Context, completion: @escaping (PayloadEntry) -> Void) {
        completion(PayloadEntry(date: .now, payload: WidgetStore.read()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<PayloadEntry>) -> Void) {
        completion(Timeline(entries: [PayloadEntry(date: .now, payload: WidgetStore.read())], policy: .never))
    }
}

private struct Artwork: View {
    let file: String?
    var body: some View {
        if let url = WidgetStore.artworkURL(file: file), let img = UIImage(contentsOfFile: url.path) {
            Image(uiImage: img).resizable().scaledToFill()
        } else {
            ZStack { Color.gray.opacity(0.3); Image(systemName: "music.note").foregroundStyle(.secondary) }
        }
    }
}

struct SpotlightsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: PayloadEntry

    var body: some View {
        let items = entry.payload.spotlights ?? []
        Group {
            if items.isEmpty {
                VStack(spacing: 4) {
                    Image(systemName: "star")
                    Text("No spotlights yet today").font(.caption).multilineTextAlignment(.center)
                }
            } else if family == .accessoryRectangular {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Spotlights today").font(.caption2).foregroundStyle(.secondary)
                    Text(items[0].title).font(.caption.weight(.semibold)).lineLimit(1)
                    Text("\(items[0].username) · \(items[0].artist)").font(.caption2).lineLimit(1)
                }
            } else if family == .systemSmall {
                row(items[0])
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Friends' spotlights today").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(items.prefix(3)) { row($0) }
                }
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private func row(_ s: WidgetPayload.Spotlight) -> some View {
        HStack(spacing: 8) {
            Artwork(file: s.artworkFile).frame(width: 40, height: 40).clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 1) {
                Text(s.title).font(.caption.weight(.semibold)).lineLimit(1)
                Text("\(s.username) · \(s.artist)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

struct NowPlayingWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: PayloadEntry

    var body: some View {
        Group {
            if let np = entry.payload.nowPlaying {
                if family == .accessoryRectangular {
                    VStack(alignment: .leading, spacing: 1) {
                        Label(np.isPlaying ? "Now playing" : "Paused", systemImage: np.isPlaying ? "waveform" : "pause.fill")
                            .font(.caption2).foregroundStyle(.secondary)
                        Text(np.title).font(.caption.weight(.semibold)).lineLimit(1)
                        Text(np.artist).font(.caption2).lineLimit(1)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Artwork(file: np.artworkFile).frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 8))
                        Text(np.title).font(.caption.weight(.semibold)).lineLimit(2)
                        Text(np.artist).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                VStack(spacing: 4) {
                    Image(systemName: "music.note")
                    Text("Nothing playing").font(.caption)
                }
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct SpotlightsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NodalongSpotlights", provider: PayloadProvider()) { SpotlightsWidgetView(entry: $0) }
            .configurationDisplayName("Friends' spotlights")
            .description("Today's spotlights from people you follow.")
            .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

struct NowPlayingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NodalongNowPlaying", provider: PayloadProvider()) { NowPlayingWidgetView(entry: $0) }
            .configurationDisplayName("Now playing")
            .description("What you're listening to in Nodalong.")
            .supportedFamilies([.systemSmall, .accessoryRectangular])
    }
}
