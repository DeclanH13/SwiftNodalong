import SwiftUI

/// The app's typeface — Quicksand, per the brand guidelines (`docs/
/// Nodalong_Brand_Guidelines.pdf`), across its 5 documented weights (Light/
/// Regular/Medium/SemiBold/Bold). Registered via `UIAppFonts` in `Info.plist`
/// as 5 static instances extracted from Google Fonts' variable-font release
/// (`fonttools varLib.instancer`, PostScript names `Quicksand-<Weight>`) —
/// there was no existing font infrastructure in this app before this; every
/// screen previously used the system font.
///
/// Mirrors `Color.nodalong`'s naming convention: one static property per
/// system text style this app actually uses (found by inventorying every
/// `.font(...)` call site in the app before writing this — 322 sites across
/// 39 files, reduced to the styles below by frequency), each backed by
/// `Font.custom(_:size:relativeTo:)` so Dynamic Type scaling still works.
/// Weight mapping: a style with no explicit `.weight(...)`/`.bold()` in its
/// old call site uses Regular, **except `headline`** — the system's own
/// `.headline` renders semibold by default (Apple HIG's built-in emphasis
/// for headline text), so it maps to SemiBold here too, to preserve that
/// visual weight rather than flattening every plain style to Regular.
///
/// **Coverage is app-wide.** Every SwiftUI `Text` renders in Quicksand,
/// including the fixed-point-size call sites (via `custom(_:_:)` below) and
/// every `MarqueeText`'s `font:` argument. Nav bar titles and tab bar labels
/// are drawn by UIKit and can't be reached from here — `AppChrome` applies
/// the same face to those.
///
/// Two deliberate exceptions, both correct: **SF Symbol glyphs** keep
/// `.font(.system(size:))` (a custom face can't improve a symbol, and SF
/// Symbols are metric-matched to SF), and **emoji** (`AvatarView`,
/// `AvatarPickerView`) do too, since Quicksand carries no emoji glyphs.
extension Font {
    enum nodalong {
        // MARK: — Caption
        static let caption               = Font.custom("Quicksand-Regular",  size: 12, relativeTo: .caption)
        static let captionMedium         = Font.custom("Quicksand-Medium",   size: 12, relativeTo: .caption)
        static let captionSemibold       = Font.custom("Quicksand-SemiBold", size: 12, relativeTo: .caption)
        static let captionBold           = Font.custom("Quicksand-Bold",     size: 12, relativeTo: .caption)

        static let caption2              = Font.custom("Quicksand-Regular",  size: 11, relativeTo: .caption2)
        static let caption2Semibold      = Font.custom("Quicksand-SemiBold", size: 11, relativeTo: .caption2)
        static let caption2Bold          = Font.custom("Quicksand-Bold",     size: 11, relativeTo: .caption2)

        // MARK: — Footnote
        static let footnote              = Font.custom("Quicksand-Regular",  size: 13, relativeTo: .footnote)
        static let footnoteMedium        = Font.custom("Quicksand-Medium",   size: 13, relativeTo: .footnote)
        static let footnoteSemibold      = Font.custom("Quicksand-SemiBold", size: 13, relativeTo: .footnote)

        // MARK: — Subheadline
        static let subheadline           = Font.custom("Quicksand-Regular",  size: 15, relativeTo: .subheadline)
        static let subheadlineMedium     = Font.custom("Quicksand-Medium",   size: 15, relativeTo: .subheadline)
        static let subheadlineSemibold   = Font.custom("Quicksand-SemiBold", size: 15, relativeTo: .subheadline)

        /// SemiBold, not Regular — see this type's own doc comment: the
        /// system's `.headline` is semibold by default, and this preserves
        /// that emphasis rather than flattening it.
        static let headline              = Font.custom("Quicksand-SemiBold", size: 17, relativeTo: .headline)
        static let body                  = Font.custom("Quicksand-Regular",  size: 17, relativeTo: .body)
        static let callout                = Font.custom("Quicksand-Regular",  size: 16, relativeTo: .callout)

        // MARK: — Title
        static let title3                = Font.custom("Quicksand-Regular",  size: 20, relativeTo: .title3)
        static let title3Semibold        = Font.custom("Quicksand-SemiBold", size: 20, relativeTo: .title3)
        static let title3Bold            = Font.custom("Quicksand-Bold",     size: 20, relativeTo: .title3)

        static let title2                = Font.custom("Quicksand-Regular",  size: 22, relativeTo: .title2)
        static let title2Bold            = Font.custom("Quicksand-Bold",     size: 22, relativeTo: .title2)

        static let title                 = Font.custom("Quicksand-Regular",  size: 28, relativeTo: .title)
        static let titleBold             = Font.custom("Quicksand-Bold",     size: 28, relativeTo: .title)

        static let largeTitle            = Font.custom("Quicksand-Regular",  size: 34, relativeTo: .largeTitle)

        // MARK: — Fixed-size

        /// Quicksand at an explicit point size, for the handful of call sites
        /// that genuinely need one (badges, compact tile captions, the splash
        /// wordmark) rather than a semantic text style.
        ///
        /// Prefer the named styles above wherever one fits — they scale with
        /// Dynamic Type, this does not. Use this only where the previous code
        /// already used `.font(.system(size:))` for *text*; SF Symbol glyphs
        /// deliberately stay on `.system(size:)`, since a custom font can't
        /// improve a symbol and SF Symbols are metric-matched to SF.
        static func custom(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
            let face: String
            switch weight {
            case .light, .ultraLight, .thin: face = "Quicksand-Light"
            case .medium:                    face = "Quicksand-Medium"
            case .semibold:                  face = "Quicksand-SemiBold"
            case .bold, .heavy, .black:      face = "Quicksand-Bold"
            default:                         face = "Quicksand-Regular"
            }
            return .custom(face, fixedSize: size)
        }

        /// For the handful of call sites where weight is chosen dynamically
        /// (e.g. a selected-vs-unselected tab) rather than fixed — mirrors
        /// the same `.subheadline` size/relativeTo as the static properties
        /// above, just with the weight left as a parameter.
        static func subheadline(emphasized: Bool) -> Font {
            emphasized ? subheadlineSemibold : subheadline
        }
    }
}
