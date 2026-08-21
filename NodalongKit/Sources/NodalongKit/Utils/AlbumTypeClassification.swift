import Foundation

// MusicKit's own `isSingle`/`isCompilation` flags are not always reliable —
// a release that's clearly a single or EP by its own title can still come
// back with `isSingle == false`, landing it in an artist's own "Albums" tab
// instead of "Discovery" (originally named "Singles & EPs" — see
// `ArtistDetailSearchView.DiscographyTab`'s own doc comment — before it
// absorbed "Features on" too, so an EP belongs there by original product
// intent, not just a single). Two independent title-based signals, used as
// an ADDITIONAL check alongside the MusicKit flags, not a replacement:
//
// - A bracketed featured-artist credit ("Trouble (feat. Childish Gambino)")
//   — a real album is essentially never itself titled with a "(feat. ...)"
//   credit; that credit belongs to the one song, which is what marks the
//   release as a single. Same vocabulary as
//   `SearchQueryNormalization.stripSearchNoise`/`primaryArtist` (feat./ft./
//   featuring/with), restricted to a bracketed credit specifically so a
//   legitimate album title that happens to contain the word "with"
//   elsewhere isn't caught.
// - A trailing "- Single" / "- EP" suffix ("Summer Pack - Single") — the
//   same store-suffix convention already referenced in
//   `ReleaseMatching.albumNamesMatch`'s own doc comment, here read as a
//   release-type label rather than stripped for name matching.
private let featuredCreditPattern = #"[\(\[](feat\.?|ft\.?|featuring|with)\s"#
private let trailingReleaseTypePattern = #"-\s*(single|ep)\s*$"#

/// Compiled once — these previously recompiled on every call. Kept
/// `Optional` + `try?` so failure semantics match the previous inline code.
private enum ReleaseTypeRx {
    static let featuredCredit: NSRegularExpression? = try? NSRegularExpression(
        pattern: featuredCreditPattern, options: .caseInsensitive)
    static let trailingReleaseType: NSRegularExpression? = try? NSRegularExpression(
        pattern: trailingReleaseTypePattern, options: .caseInsensitive)
}

public func titleIndicatesSingleOrEP(_ title: String) -> Bool {
    let range = NSRange(title.startIndex..., in: title)
    if let regex = ReleaseTypeRx.featuredCredit,
       regex.firstMatch(in: title, range: range) != nil {
        return true
    }
    if let regex = ReleaseTypeRx.trailingReleaseType,
       regex.firstMatch(in: title, range: range) != nil {
        return true
    }
    return false
}
