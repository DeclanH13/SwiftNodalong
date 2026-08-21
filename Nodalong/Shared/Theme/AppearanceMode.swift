import SwiftUI

/// User's chosen appearance override, persisted via `@AppStorage` under
/// `appearanceModeKey`. `.system` (the default) means "follow the OS
/// setting" — the app's only behavior before this toggle existed, and still
/// the behavior for anyone who never touches the new picker.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    /// Value to hand to `.preferredColorScheme(_:)`. `nil` for `.system`
    /// tells SwiftUI to defer to the OS setting instead of forcing one.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }

    var label: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }
}

/// Shared `UserDefaults` key so `NodalongApp` (reads, to apply the override)
/// and `ProfileView` (writes, via the picker) stay in sync through the same
/// `@AppStorage` binding.
let appearanceModeKey = "nodalong.appearanceMode"

/// `@AppStorage` key for "the user chose to skip music-service onboarding".
/// Lives here beside `appearanceModeKey` so every persisted preference key is
/// declared in one place. See `ContentView.skippedMusicLink`.
let skippedMusicLinkKey = "nodalong.skippedMusicLink"
