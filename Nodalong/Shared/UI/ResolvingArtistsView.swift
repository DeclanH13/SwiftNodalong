import SwiftUI
import NodalongKit

/// Same shape as `ResolvingArtistView`, for a track that may credit more
/// than one artist (e.g. "Jamie xx & Honey Dijon") — pushed/presented
/// immediately with the already-known name, resolves in the background, and
/// either swaps straight to `ArtistDetailSearchView` (exactly one credited
/// artist) or shows an inline picker (more than one) instead of silently
/// guessing.
///
/// The picker lives inside this already-presented view rather than a second
/// `.sheet` — replaces the previous dismiss-then-present timing hack
/// (`DispatchQueue.main.asyncAfter`) that used to be needed to swap between
/// two separate sheets without them conflicting.
struct ResolvingArtistsView: View {
    let name: String
    let resolve: () async -> [ArtistResult]

    @State private var candidates: [ArtistResult] = []
    @State private var chosen: ArtistResult?
    @State private var notFound = false

    /// See `ResolvingAlbumView.init`. One cached artist lands straight on
    /// their page; several land straight on the picker.
    init(name: String, cached: [ArtistResult]? = nil, resolve: @escaping () async -> [ArtistResult]) {
        self.name = name
        self.resolve = resolve
        let cached = cached ?? []
        _chosen = State(initialValue: cached.count == 1 ? cached[0] : nil)
        _candidates = State(initialValue: cached.count > 1 ? cached : [])
    }

    var body: some View {
        Group {
            if let chosen {
                ArtistDetailSearchView(artist: chosen)
            } else if candidates.count > 1 {
                List {
                  // A native section header rather than a pinned title band:
                  // a bare list of artist names doesn't say what to do with
                  // them, and this scrolls with the content.
                  Section("Choose Artist") {
                   ForEach(candidates) { artist in
                    Button {
                        chosen = artist
                    } label: {
                        HStack(spacing: 12) {
                            let sizedURL = ArtworkURL.sized(artist.imageUrl, points: 44)
                            Group {
                                if sizedURL.isEmpty {
                                    Color.nodalong.bgCard
                                } else {
                                    CachedArtworkImage(
                                        urlString: sizedURL,
                                        placeholder: { Color.nodalong.bgCard },
                                        failure: { Color.nodalong.bgCard }
                                    )
                                }
                            }
                            .frame(width: 44, height: 44)
                            .clipShape(Circle())

                            Text(artist.name)
                                .foregroundStyle(Color.nodalong.textPrimary)

                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.nodalong.bgCard)
                   }
                  }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .screenBackground()
                .screenControls()
            } else {
                VStack(spacing: 16) {
                    Circle()
                        .fill(Color.nodalong.bgCard)
                        .frame(width: 120, height: 120)
                        .overlay {
                            Image(systemName: "music.mic")
                                .font(.system(size: 40))
                                .foregroundStyle(Color.nodalong.textPrimary.opacity(0.4))
                        }
                    Text(name)
                        .font(Font.nodalong.title3Bold)
                        .foregroundStyle(Color.nodalong.textPrimary)
                        .multilineTextAlignment(.center)
                    if notFound {
                        Text("Couldn't find this artist")
                            .font(Font.nodalong.subheadline)
                            .foregroundStyle(Color.nodalong.textSecondary)
                    } else {
                        ProgressView()
                    }
                }
                .padding(.horizontal, 32)
                .padding(.top, 40)
                // maxHeight (not just maxWidth) — see ResolvingAlbumView's
                // matching fix: without it the background only colors this
                // VStack's own content-sized box, leaving black bands above
                // and below it (the system default in dark mode) instead of
                // filling the screen.
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .screenBackground()
                .screenControls()
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .task {
            guard chosen == nil, candidates.isEmpty, !notFound else { return }
            let results = await resolve()
            if results.count == 1 {
                chosen = results[0]
            } else if results.isEmpty {
                notFound = true
            } else {
                candidates = results
            }
        }
    }
}
