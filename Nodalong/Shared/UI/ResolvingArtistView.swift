import SwiftUI
import NodalongKit

/// Same shape as `ResolvingAlbumView`, for an artist tap — pushed
/// immediately with the already-known name, resolves the real catalog
/// artist in the background, then swaps in `ArtistDetailSearchView`.
///
/// The unresolved placeholder deliberately mirrors `ArtistDetailSearchView.
/// heroSection`'s exact footprint (340pt full-bleed rectangle, top-of-screen
/// bleed, bottom-left gradient + name) rather than a generic centered circle
/// + spinner. Reached from a text tap with no tile artwork to zoom-transition
/// from, so this is the only lever available to make the resolve→loaded swap
/// feel continuous instead of a jump cut between two differently-shaped
/// screens — deliberately duplicated rather than extracted into a shared
/// component, since `heroSection` has a documented history of breaking when
/// touched (see its own doc comment) and this only needs to approximate its
/// look, not share its logic.
struct ResolvingArtistView: View {
    let name: String
    let resolve: () async -> ArtistResult?

    @State private var resolved: ArtistResult?
    @State private var notFound = false

    /// See `ResolvingAlbumView.init` — a cache hit at push time skips the
    /// placeholder entirely.
    init(name: String, cached: ArtistResult? = nil, resolve: @escaping () async -> ArtistResult?) {
        self.name = name
        self.resolve = resolve
        _resolved = State(initialValue: cached)
    }

    var body: some View {
        Group {
            if let resolved {
                ArtistDetailSearchView(artist: resolved)
                    .transition(.opacity)
            } else {
                ZStack(alignment: .topLeading) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        placeholderHero
                        if notFound {
                            Text("Couldn't find this artist")
                                .font(Font.nodalong.subheadline)
                                .foregroundStyle(Color.nodalong.textSecondary)
                                .padding(24)
                        }
                    }
                }
                .ignoresSafeArea(edges: .top)

                }
                .screenBackground()
                // Floating, matching `ArtistDetailSearchView` — this
                // placeholder deliberately mirrors that screen so the
                // resolve→loaded swap doesn't jump, which means matching how
                // its controls are positioned too.
                .screenControls()
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.25), value: resolved != nil)
        .toolbar(.hidden, for: .navigationBar)
        .task {
            guard resolved == nil, !notFound else { return }
            if let result = await resolve() {
                resolved = result
            } else {
                notFound = true
            }
        }
    }

    @ViewBuilder
    private var placeholderHero: some View {
        Color.nodalong.bgCard
            .frame(maxWidth: .infinity)
            .frame(height: 340)
            .overlay {
                if notFound {
                    Image(systemName: "music.mic")
                        .font(.system(size: 40))
                        .foregroundStyle(Color.nodalong.textPrimary.opacity(0.4))
                } else {
                    ShimmerView()
                }
            }
            .clipped()
            .overlay(alignment: .bottomLeading) {
                LinearGradient(
                    colors: [.clear, .clear, Color.black.opacity(0.75)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .overlay(alignment: .bottomLeading) {
                    Text(name)
                        .font(Font.nodalong.titleBold)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .shadow(color: .black.opacity(0.6), radius: 6, y: 2)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 16)
                }
            }
    }
}
