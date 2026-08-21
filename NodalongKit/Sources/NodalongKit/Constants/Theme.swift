public enum Theme {
    public enum Colors {
        // MARK: — Backgrounds
        /// Primary screen background — deepest violet-black.
        public static let bgBase    = "#1e1640"
        /// Elevated surface background — rich plum for tab bar, raised cards.
        public static let bgSurface = "#2c2358"
        /// Deepest background — used on splash and auth screens.
        public static let bgDeep    = "#200364"

        // MARK: — Purple scale
        /// Pale tint — highlights, selection rings.
        public static let purplePale   = "#e4d9fd"
        /// Soft purple — light decorative use.
        public static let purpleSoft   = "#c6affc"
        /// Main accent purple — selected tab icons, hearts, link text.
        public static let purpleAccent = "#b89fff"
        /// Bold purple — high-emphasis buttons (e.g. Enable Location).
        public static let purpleBold   = "#5721d4"
        /// Mid purple — primary CTA buttons and follow buttons.
        public static let purpleMid    = "#6645b5"
        /// Dark purple — mini player pill, prominent brand elements.
        public static let purpleDark   = "#5b21b6"

        // MARK: — Semantic
        /// Gold / amber — Apple Music badges, spotlight stars.
        public static let gold      = "#f7bc0c"
        /// Error — destructive actions and error states.
        public static let error     = "#9b095c"
        /// Light error tint.
        public static let errorTint = "#fcc4e4"

        // MARK: — Neutral (legacy light-mode grays, kept for completeness)
        public static let neutralWhite  = "#f9f9f9"
        public static let neutral100    = "#f0f0f0"
        public static let neutral200    = "#e8e8e8"
        public static let neutral300    = "#dcdcdc"
        public static let neutral400    = "#cccccc"
        public static let neutral500    = "#39324a"
        public static let neutral600    = "#333333"
        public static let neutral900    = "#999999"

        // MARK: — Gold decorative scale (kept for future use)
        public static let goldTint  = "#faf6e9"
        public static let goldLight = "#f0e4b8"
        public static let goldMid   = "#d4af37"

        public static let white = "#ffffff"
        public static let black = "#000000"
    }
}
