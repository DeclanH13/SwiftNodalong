import MediaPlayer
import SwiftUI

/// System volume slider rendered via `MPVolumeView`.
///
/// `MPVolumeView` is the only iOS-sanctioned way to control the real device
/// output volume from a third-party app. It renders Apple's native volume
/// track UI, handles Bluetooth/AirPlay routing, and responds to the hardware
/// volume buttons — behaviours that a custom `Slider` on `AVAudioSession`
/// cannot replicate.
///
/// Tint tracks the app's adaptive ink color (`textPrimary`) so the slider
/// reads well against `NowPlayingView`'s background in both light and dark
/// mode — that background is a blurred rendition of the track's own artwork
/// plus `Color.nodalong.bgBase`, which is no longer always dark now that
/// light mode exists. `UIColor(named:)`, not a `Color` conversion, so it
/// stays trait-aware rather than freezing at whatever appearance was active
/// when this view was first created.
/// The AirPlay route picker button is hidden (`showsRouteButton = false`) since
/// NowPlayingView has no dedicated AirPlay affordance yet.
///
/// Usage: `SystemVolumeSlider().frame(height: 32)`
struct SystemVolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let v = MPVolumeView()
        v.tintColor = (UIColor(named: "textPrimary") ?? .white).withAlphaComponent(0.85)
        // `showsRouteButton` is deprecated in favor of a separate `AVRoutePickerView`
        // — but that's an additive widget, not a togglable flag on `MPVolumeView`, so
        // there's no non-deprecated way to keep a bare slider with the button hidden
        // short of building a real AirPlay picker UI (out of scope here — see this
        // file's header doc comment). Wrapping this in a helper marked
        // `@available(deprecated:)` was tried and does NOT suppress the warning —
        // Swift's deprecated-calling-deprecated leniency only covers uses *inside*
        // a deprecated declaration's own body, it doesn't extend outward to
        // whoever then calls that declaration — so this is left as a plain,
        // knowingly-unavoidable warning rather than a wrapper that just relocates it.
        v.showsRouteButton = false
        return v
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}
