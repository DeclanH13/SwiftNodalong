import SwiftUI
import NodalongKit

/// "Your week" — last Monday→Sunday at a glance, with a Share button that
/// renders the same card as an image.
struct WeeklyRecapCard: View {
    let recap: WeeklyRecap

    @State private var shareImage: Image?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RecapContent(recap: recap)
                .padding(16)
                .background(Color.nodalong.bgCard)
                .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
            if let shareImage {
                ShareLink(item: shareImage, preview: SharePreview("My week on Nodalong", image: shareImage)) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .font(Font.nodalong.subheadlineSemibold)
                }
            }
        }
        .padding(.horizontal, 16)
        .task(id: recap) { render() }
    }

    @MainActor private func render() {
        let card = RecapContent(recap: recap)
            .padding(32)
            .frame(width: 540)
            .background(Color(red: 0.43, green: 0.24, blue: 0.49))
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: card)
        renderer.scale = 2
        if let ui = renderer.uiImage { shareImage = Image(uiImage: ui) }
    }
}

private struct RecapContent: View {
    let recap: WeeklyRecap

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your week").font(Font.nodalong.headline).foregroundStyle(Color.nodalong.textPrimary)
            if recap.playCount > 0 {
                Text("\(recap.playCount) plays").font(Font.nodalong.subheadlineSemibold)
                    .foregroundStyle(Color.nodalong.textPrimary)
                ForEach(Array(recap.topArtists.enumerated()), id: \.offset) { i, a in
                    Text("\(i + 1). \(a.name) · \(a.plays)×").font(Font.nodalong.caption)
                        .foregroundStyle(Color.nodalong.textSecondary)
                }
            }
            line(recap.savedCount, "saved to Shelf")
            line(recap.spotlightCount, "spotlighted")
            line(recap.nodsReceived, "nods received")
            if let s = recap.mostInSync {
                Text("Most in sync with \(s.username) · \(s.sharedArtists) shared artists")
                    .font(Font.nodalong.caption).foregroundStyle(Color.nodalong.textSecondary)
            }
            if let p = recap.friendTrackOfTheWeek {
                Text("Friends' pick: \(p.title) — \(p.artist)")
                    .font(Font.nodalong.caption).foregroundStyle(Color.nodalong.textSecondary).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func line(_ n: Int, _ label: String) -> some View {
        if n > 0 {
            Text("\(n) \(label)").font(Font.nodalong.caption).foregroundStyle(Color.nodalong.textSecondary)
        }
    }
}
