import SwiftUI
import NodalongKit

/// "Alternative versions" — the other editions of a release (clean vs.
/// explicit, deluxe, remaster) that `dedupeAlbumEditions` folds away from the
/// main discography so it doesn't show visible duplicates.
///
/// Extracted from `AlbumDetailSearchView`, which was the only screen with it.
/// Shelf's own album screen and Home's Recently Added quick view show the same
/// section now, so an album lists its other editions however you reached it —
/// previously it did so only when reached from an artist page, because that is
/// the sole path where `alternates` was ever populated.
///
/// Tapping a row pushes that edition's own `AlbumDetailSearchView`, resolved
/// independently. Every stack this can appear on already registers an
/// `AlbumResult` destination.
struct AlternateVersionsSection: View {
    @EnvironmentObject private var router: AppRouter
    let alternates: [AlbumResult]

    @EnvironmentObject private var musicService: AppleMusicService
    @EnvironmentObject private var playerVM:     PlayerViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Alternative versions")
                .font(Font.nodalong.headline)
                .foregroundStyle(Color.nodalong.textPrimary)
                .padding(.horizontal, 16)
                .padding(.top, 24)
                .padding(.bottom, 12)

            VStack(spacing: 0) {
                ForEach(Array(alternates.enumerated()), id: \.element.id) { idx, alt in
                    Button {
                        router.push(alt, identity: .album(name: alt.name, artist: alt.artistName))
                    } label: {
                        row(alt)
                    }
                    .buttonStyle(.plain)
                    // Per-row prefetch, same as every other tappable album in
                    // the app — an alternate edition is a likely next tap.
                    .task(id: alt.id, priority: .utility) {
                        guard playerVM.activeService == .appleMusic else { return }
                        await CatalogPrefetch.album(id: alt.id, name: alt.name,
                                                    artwork: alt.artwork, releaseDate: alt.releaseDate,
                                                    artist: alt.artistName, service: musicService)
                    }
                    if idx < alternates.count - 1 {
                        Divider()
                            .background(Color.nodalong.bgCard.opacity(0.4))
                            .padding(.leading, 72)
                    }
                }
            }
            .background(Color.nodalong.bgCard)
            .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
            .padding(.horizontal, 16)
        }
    }

    private func row(_ alt: AlbumResult) -> some View {
        HStack(spacing: 12) {
            ArtworkThumbnail(url: alt.artwork, size: 44, isAlbum: true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(alt.name)
                        .font(Font.nodalong.subheadlineMedium)
                        .foregroundStyle(Color.nodalong.textPrimary)
                        .lineLimit(1)
                    if alt.isExplicit { ExplicitBadge() }
                }
                if let label = alt.editionLabel {
                    Text(label)
                        .font(Font.nodalong.caption)
                        .foregroundStyle(Color.nodalong.textSecondary)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(Font.nodalong.caption)
                .foregroundStyle(Color.nodalong.textSecondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
