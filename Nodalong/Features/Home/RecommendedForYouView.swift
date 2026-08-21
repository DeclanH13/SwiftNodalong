import SwiftUI
import NodalongKit

/// "See All" detail screen for Home's Recommended for You section — pushed
/// via `SeeAllRecommendations`. Re-fetches with a higher group limit (10,
/// Apple's documented max for this request) than Home's own compact preview
/// (5), so there's genuinely more to see here, not just the same shelves
/// re-shown.
struct RecommendedForYouView: View {
    @EnvironmentObject private var musicService: AppleMusicService

    /// Shares `HomeView.zoomNamespace` — this screen is always pushed onto
    /// Home's own `NavigationStack`, so its tap→open zoom transitions must
    /// use the same namespace Home's `.navigationDestination(for:)` expects.
    let namespace: Namespace.ID

    @State private var shelves: [RecommendationShelf] = []
    @State private var isLoading = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                } else {
                    ForEach(shelves) { shelf in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(shelf.title)
                                .font(Font.nodalong.headline)
                                .foregroundStyle(Color.nodalong.textPrimary)
                                .padding(.horizontal, 16)
                            AlbumsCarousel(albums: shelf.albums, namespace: namespace)
                        }
                    }
                }
            }
            .padding(.vertical, 16)
        }
        .background(Color.nodalong.bgBase)
        .navigationTitle("Recommended for You")
        .navigationBarTitleDisplayMode(.inline)
        // No `.navigationDestination(for: AlbumResult.self)` here — this
        // view is always pushed onto HomeView's own NavigationStack, which
        // already declares that destination; a duplicate would be redundant.
        .task {
            shelves = (try? await musicService.getPersonalRecommendations(maxGroups: 10)) ?? []
            isLoading = false
        }
    }
}

#if DEBUG
private struct RecommendedForYouPreviewHost: View {
    @Namespace private var namespace
    var body: some View {
        NavigationStack {
            RecommendedForYouView(namespace: namespace)
        }
        .withPreviewEnvironment()
    }
}

#Preview {
    RecommendedForYouPreviewHost()
}
#endif
