import SwiftUI
import NodalongKit

/// Push value for the Taste screen.
struct TasteRoute: Hashable {}

/// Review and change what the app thinks you like. "Play less" keeps an artist
/// at 30% weight; "Never suggest" removes them from suggestions and search
/// boosts entirely.
struct TasteView: View {
    @EnvironmentObject private var tasteStore: TasteOverridesStore
    @EnvironmentObject private var libraryVM: LibraryViewModel
    @State private var query = ""

    private func displayName(forKey key: String) -> String {
        libraryVM.artistEntries.first { TasteOverrides.key($0.name) == key }?.name ?? key.capitalized
    }

    private var artists: [ArtistEntry] {
        let all = libraryVM.artistEntries.sorted { $0.trackCount > $1.trackCount }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? Array(all.prefix(50)) : all.filter { $0.name.lowercased().contains(q) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ScreenTitle("Your taste")
                Text("Artists you play less or never want suggested. This only affects your own suggestions and search.")
                    .font(Font.nodalong.caption).foregroundStyle(Color.nodalong.textSecondary)
                    .padding(.horizontal, 16)

                if !tasteStore.overrides.blocked.isEmpty {
                    group("Never suggest", keys: tasteStore.overrides.blocked.sorted())
                }
                if !tasteStore.overrides.reduced.isEmpty {
                    group("Play less", keys: tasteStore.overrides.reduced.sorted())
                }

                Text("Your artists").font(Font.nodalong.headline)
                    .foregroundStyle(Color.nodalong.textPrimary).padding(.horizontal, 16)
                TextField("Find an artist", text: $query)
                    .padding(10)
                    .background(Color.nodalong.bgCard)
                    .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
                    .padding(.horizontal, 16)
                VStack(spacing: 0) {
                    ForEach(artists, id: \.name) { artist in
                        HStack {
                            Text(artist.name).font(Font.nodalong.subheadline)
                                .foregroundStyle(Color.nodalong.textPrimary).lineLimit(1)
                            Spacer()
                            Menu {
                                Button("Play less") { tasteStore.reduce(artist.name) }
                                Button("Never suggest", role: .destructive) { tasteStore.block(artist.name) }
                            } label: {
                                Image(systemName: "ellipsis.circle").foregroundStyle(Color.nodalong.purpleAccent)
                            }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                    }
                }
                .background(Color.nodalong.bgCard)
                .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
                .padding(.horizontal, 16)
            }
            .padding(.vertical, 16)
        }
        .screenBackground()
        .toolbar(.hidden, for: .navigationBar)
        .screenControls()
    }

    private func group(_ title: String, keys: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(Font.nodalong.headline)
                .foregroundStyle(Color.nodalong.textPrimary).padding(.horizontal, 16)
            VStack(spacing: 0) {
                ForEach(keys, id: \.self) { key in
                    HStack {
                        Text(displayName(forKey: key)).font(Font.nodalong.subheadline)
                            .foregroundStyle(Color.nodalong.textPrimary)
                        Spacer()
                        Button("Undo") { tasteStore.clear(key: key) }
                            .font(Font.nodalong.captionBold).foregroundStyle(Color.nodalong.purpleAccent)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                }
            }
            .background(Color.nodalong.bgCard)
            .clipShape(RoundedRectangle(cornerRadius: Corner.container, style: .continuous))
            .padding(.horizontal, 16)
        }
    }
}
