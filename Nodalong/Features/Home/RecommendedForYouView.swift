import SwiftUI
import NodalongKit

/// "See All" detail screen for Home's Recommended for You section — pushed
/// via `SeeAllRecommendations`. Re-fetches with a higher group limit (10,
/// Apple's documented max for this request) than Home's own compact preview
/// (5), so there's genuinely more to see here, not just the same shelves
/// re-shown.
struct RecommendedForYouView: View {
    @EnvironmentObject private var musicService: AppleMusicService

    @State private var shelves: [RecommendationShelf]
    @State private var isLoading: Bool

    /// Seeds from what Home warmed in the background
    /// (`HomeViewModel.allRecommendationShelves`), so the screen opens
    /// populated instead of on a spinner. Taken as a parameter rather than
    /// read from the environment so the seed is in place for the first frame.
    init(prefetched: [RecommendationShelf] = []) {
        _shelves = State(initialValue: prefetched)
        _isLoading = State(initialValue: prefetched.isEmpty)
    }

    var body: some View {
        VStack(spacing: 0) {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // In-content heading: the shelves below are titled
                // individually, so nothing else names the screen itself.
                ScreenTitle("Recommended for You")
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
                            AlbumsCarousel(albums: shelf.albums)
                        }
                    }
                }
            }
            .padding(.vertical, 16)
        }
        }
        .screenBackground()
        .toolbar(.hidden, for: .navigationBar)
        .screenControls()
        // No `.navigationDestination(for: AlbumResult.self)` here — this
        // view is always pushed onto HomeView's own NavigationStack, which
        // already declares that destination; a duplicate would be redundant.
        .task {
            guard shelves.isEmpty else { return }
            shelves = (try? await musicService.getPersonalRecommendations(maxGroups: 10)) ?? []
            isLoading = false
        }
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        RecommendedForYouView()
    }
    .withPreviewEnvironment()
}
#endif
