import SwiftUI

/// User's chosen album-artwork rendering, persisted via `@AppStorage` under
/// `albumArtworkStyleKey`. Read locally and reactively by every
/// `ArtworkThumbnail(isAlbum: true)` instance — unlike `AppearanceMode`,
/// this needs no root-level wiring (no `.preferredColorScheme`-style
/// modifier applied once at `NodalongApp`'s root).
enum AlbumArtworkStyle: String, CaseIterable, Identifiable {
    case square, vinyl

    var id: String { rawValue }

    var label: String {
        switch self {
        case .square: return "Square"
        case .vinyl:  return "Vinyl"
        }
    }
}

/// Shared `UserDefaults` key so every `ArtworkThumbnail` (reads) and
/// `ProfileView`'s picker (writes) stay in sync through the same
/// `@AppStorage` binding. Default is `.vinyl` — already shipped and
/// approved on the artist page's discography grid before this setting
/// existed; `.square` is the opt-out, not the default.
let albumArtworkStyleKey = "nodalong.albumArtworkStyle"
