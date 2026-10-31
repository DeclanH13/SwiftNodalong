import SwiftUI
import NodalongKit

/// What two people share. Genre-first when both sides have genre data —
/// "Strong match in Hip-Hop and Alternative", then who they both play in each —
/// and the plain shared-artist line when they don't.
struct TasteMatchCard: View {
    let genre: GenreTasteMatch?
    let fallback: TasteMatch?

    private func bandLabel(_ band: TasteMatch.Band) -> String {
        switch band {
        case .strong: return "Strong match"
        case .some:   return "Some overlap"
        case .little: return "A little in common"
        }
    }

    private func list(_ names: [String]) -> String {
        switch names.count {
        case 0, 1: return names.first ?? ""
        case 2:    return "\(names[0]) and \(names[1])"
        default:   return names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let genre {
                Text("\(bandLabel(genre.band)) in \(list(genre.overlaps.map(\.genre)))")
                    .font(Font.nodalong.subheadlineSemibold)
                    .foregroundStyle(Color.nodalong.textPrimary)
                ForEach(genre.overlaps, id: \.genre) { overlap in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(overlap.genre).font(Font.nodalong.captionBold)
                            .foregroundStyle(Color.nodalong.textSecondary)
                        Text("You both play \(list(overlap.sharedArtists))")
                            .font(Font.nodalong.caption)
                            .foregroundStyle(Color.nodalong.textPrimary)
                    }
                }
            } else if let fallback {
                let n = fallback.sharedArtists.count
                Text("\(bandLabel(fallback.band)) · \(n == 1 ? "1 artist" : "\(n) artists") in common")
                    .font(Font.nodalong.subheadlineSemibold)
                    .foregroundStyle(Color.nodalong.textPrimary)
                Text("You both play \(list(Array(fallback.sharedArtists.prefix(3))))")
                    .font(Font.nodalong.caption)
                    .foregroundStyle(Color.nodalong.textPrimary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.nodalong.bgCard)
        .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
    }
}

/// "Playing now · title — artist" with a Tune In button, shown on a profile
/// while that person is playing.
struct LiveNowCard: View {
    let user: UserProfile
    let live: UserNowPlaying
    @State private var track: CatalogTrack?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(.green).frame(width: 8, height: 8)
                Text("Playing now").font(Font.nodalong.captionBold)
                    .foregroundStyle(Color.nodalong.textSecondary)
            }
            if let track {
                Text(track.title).font(Font.nodalong.subheadlineSemibold)
                    .foregroundStyle(Color.nodalong.textPrimary).lineLimit(1)
                Text(track.artist).font(Font.nodalong.caption)
                    .foregroundStyle(Color.nodalong.textSecondary).lineLimit(1)
            }
            TuneInButton(uid: user.uid, username: user.username, isPreviewPlayback: live.isPreviewPlayback)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.nodalong.bgCard)
        .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
        .task(id: live.catalogId) {
            track = await CatalogCache.shared.metadata(for: [live.catalogId])[live.catalogId]
        }
    }
}
