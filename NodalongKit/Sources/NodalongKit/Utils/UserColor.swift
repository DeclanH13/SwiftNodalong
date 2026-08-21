// Purple/gold tones are excluded — purple is the app primary and gold is for Spotlight cards.
public let userAccentColors: [String] = [
    "#E05252", // coral red
    "#3B82F6", // sky blue
    "#10B981", // emerald
    "#F97316", // orange
    "#EC4899", // rose / pink
    "#06B6D4", // cyan
    "#6366F1", // indigo
    "#14B8A6", // teal
    "#EF4444", // bright red
    "#84CC16", // lime green
]

/// Curated set of animal emojis usable as avatars. Order is intentional:
/// mammals first (most popular), then birds, then reptiles/insects, then
/// the more whimsical choices (mythological / fictional).
///
/// Adding to this list is safe — older profiles store whatever emoji they
/// picked at the time, so dropping an emoji here would only affect new
/// pickers. Removing one would orphan any user who picked it; don't.
public let userAvatarEmojis: [String] = [
    "🐶", "🐱", "🐭", "🐹", "🐰", "🦊",
    "🐻", "🐼", "🐨", "🐯", "🦁", "🐮",
    "🐷", "🐸", "🐵", "🐔", "🐧", "🐦",
    "🐤", "🦄", "🐢", "🐝", "🦋", "🦉",
]

/// Returns a stable accent color hex for a given UID.
/// Uses Int32 wrapping arithmetic to match the JS implementation exactly.
public func getUserAccentColor(uid: String) -> String {
    var hash: Int32 = 0
    for scalar in uid.unicodeScalars {
        let code = Int32(bitPattern: scalar.value & 0xFFFF)
        hash = code &+ ((hash &<< 5) &- hash)
    }
    let index = Int(abs(hash)) % userAccentColors.count
    return userAccentColors[index]
}

/// Returns a stable avatar emoji for a given UID. Used as a placeholder
/// when an existing user hasn't picked one yet (rare — only really hit
/// during legacy-data fall-through).
public func getUserAvatarEmoji(uid: String) -> String {
    var hash: Int32 = 0
    for scalar in uid.unicodeScalars {
        let code = Int32(bitPattern: scalar.value & 0xFFFF)
        hash = code &+ ((hash &<< 7) &- hash)
    }
    return userAvatarEmojis[Int(abs(hash)) % userAvatarEmojis.count]
}
