import SwiftUI
import NodalongKit

/// Pushed immediately with already-known display data (name/artist/artwork)
/// while the real catalog album resolves in the background — avoids
/// blocking navigation on the network call the way resolve-before-push used
/// to (a tap that does nothing visible for a beat before the screen pushes).
/// Swaps to the full `AlbumDetailSearchView` once resolved.
struct ResolvingAlbumView: View {
    let name: String
    let artistName: String
    let artwork: String
    let resolve: () async -> AlbumResult?

    @State private var resolved: AlbumResult?
    @State private var notFound = false

    var body: some View {
        Group {
            if let resolved {
                AlbumDetailSearchView(album: resolved)
            } else {
                // Deliberately mirrors `AlbumDetailSearchView`'s exact
                // structure (same header size/layout, same divider-separated
                // card, same skeleton rows) instead of a standalone centered
                // spinner — the header doesn't move or resize when this
                // swaps to the real screen, and shimmer rows becoming real
                // rows reads as one continuous load finishing, not a jump
                // between two different loading styles. Not tappable here
                // (unlike the loaded screen's artist name) — there's nothing
                // meaningful to navigate to before resolution completes.
                ScrollView {
                    VStack(spacing: 0) {
                        VStack(spacing: 12) {
                            ArtworkThumbnail(url: artwork, size: AlbumDetailSearchView.heroArtworkSize, isAlbum: true)
                                .clipShape(RoundedRectangle(cornerRadius: Corner.artwork, style: .continuous))
                            VStack(spacing: 4) {
                                Text(name)
                                    .font(Font.nodalong.title3Bold)
                                    .foregroundStyle(Color.nodalong.textPrimary)
                                    .multilineTextAlignment(.center)
                                    .lineLimit(2)
                                Text(artistName)
                                    .font(Font.nodalong.subheadlineMedium)
                                    .foregroundStyle(Color.nodalong.purpleAccent)
                            }
                            .padding(.horizontal, 16)
                        }
                        .padding(.vertical, 24)

                        VStack(spacing: 0) {
                            if notFound {
                                // Deliberately does NOT fall back to "some
                                // other album by this artist" — see
                                // `AppleMusicService.resolveAlbum`'s own doc
                                // comment on why there's no best-of-what's-
                                // left step: silently opening a release whose
                                // name differs from the one just shown was a
                                // confirmed past bug. An honest miss with a
                                // way out is better than a wrong substitution,
                                // so this offers a retry instead of a dead end
                                // (resolution is often anchor-dependent and a
                                // second attempt can succeed once the catalog
                                // row has been repaired by another surface).
                                VStack(spacing: 12) {
                                    Text("Couldn't find this album")
                                        .font(Font.nodalong.subheadline)
                                        .foregroundStyle(Color.nodalong.textSecondary)
                                    Text("It may only exist as a single, or under a different release name.")
                                        .font(Font.nodalong.caption)
                                        .foregroundStyle(Color.nodalong.textTertiary)
                                        .multilineTextAlignment(.center)
                                        .padding(.horizontal, 24)
                                    Button("Try again") {
                                        notFound = false
                                        Task { await attemptResolve() }
                                    }
                                    .font(Font.nodalong.subheadlineSemibold)
                                    .foregroundStyle(Color.nodalong.purpleAccent)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 32)
                            } else {
                                ForEach(0..<5, id: \.self) { idx in
                                    ShimmerView()
                                        .frame(height: 40)
                                        .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 10)
                                    if idx < 4 {
                                        Divider()
                                            .background(Color.nodalong.bgCard.opacity(0.4))
                                            .padding(.leading, 16)
                                    }
                                }
                            }
                        }
                        .background(Color.nodalong.bgCard)
                        .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
                        .padding(.horizontal, 16)
                    }
                }
                .background(Color.nodalong.bgBase)
                .navigationTitle(name)
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .task {
            guard resolved == nil, !notFound else { return }
            await attemptResolve()
        }
    }

    /// Extracted so the failure state's "Try again" can re-run the exact
    /// same resolution the `.task` does, rather than duplicating it.
    private func attemptResolve() async {
        if let result = await resolve() {
            resolved = result
        } else {
            notFound = true
        }
    }
}
