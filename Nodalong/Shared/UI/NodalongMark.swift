import SwiftUI

/// The Nodalong brand mark (headphones over a smiling face), rendered as a
/// tintable template image at an explicit point size.
///
/// **Always use this instead of a bare `Image("nodalongMark")`.** A custom
/// image asset does NOT respond to `.font(...)` the way an SF Symbol does —
/// it renders at its own intrinsic size (the source PDF's 218×174pt) and
/// happily overflows whatever container it's in, with no clipping. That was
/// a real shipped bug: the mini player's broadcast button and the party-
/// playlist badge both rendered the mark at full intrinsic size, and three
/// oversized badges overlapping across a playlist row read as a bizarre
/// tiled wallpaper rather than one icon each. `.resizable()` +
/// `.scaledToFit()` + an explicit frame is the only thing that actually
/// constrains a custom asset.
///
/// The mark is wider than it is tall (~1.25:1), so `size` behaves like an SF
/// Symbol's point size — it bounds a square the mark is fitted inside,
/// meaning the rendered height is ~0.8 × `size`. Pick `size` to match
/// whatever `.font(.system(size:))` the SF Symbol at this call site used to
/// have, and it'll land in roughly the same visual place.
///
/// Tint with `.foregroundStyle(...)` at the call site, exactly as before —
/// the asset carries `template-rendering-intent`, so it takes the tint
/// rather than painting its own (white) source colour.
struct NodalongMark: View {
    /// Bounding size in points — see this type's own doc comment for how it
    /// relates to the mark's non-square aspect ratio.
    var size: CGFloat

    var body: some View {
        Image("nodalongMark")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
    }
}

#if DEBUG
#Preview {
    VStack(spacing: 24) {
        NodalongMark(size: 52)
        NodalongMark(size: 20)
        NodalongMark(size: 12)
        NodalongMark(size: 9)
    }
    .foregroundStyle(Color.nodalong.purpleAccent)
    .padding()
    .background(Color.nodalong.bgBase)
}
#endif
