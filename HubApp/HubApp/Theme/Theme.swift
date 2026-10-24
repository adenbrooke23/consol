import SwiftUI

// CONSOL design tokens, taken 1:1 from docs/design/style-guide.html and the
// iPad app. The same standing rules apply here:
//  • Signal: brightLemon is indication only (dots, live readouts, focus).
//    Never a fill on a control face; ≤3% of a screen.
//  • Touch: solid white marks only what you grab.
//  • Stage: the canvas is true black; depth is tonal steps + hairlines,
//    never shadows/gradients/blur.

extension Color {
    init(hex: UInt, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

enum Theme {
    // ---- Core palette (fixed) ----
    enum Core {
        static let spaceIndigo = Color(hex: 0x2B2D42)
        static let lavenderGrey = Color(hex: 0x8D99AE)
        static let brightLemon = Color(hex: 0xF8F32B)
        static let white = Color.white
        static let black = Color.black
    }

    // ---- Ramps (hue ~235°, lightness only) ----
    enum Indigo {
        static let i950 = Color(hex: 0x111220)
        static let i900 = Color(hex: 0x1B1D2E)
        static let i800 = Color(hex: 0x22243A)
        static let i700 = Color(hex: 0x2B2D42)
        static let i600 = Color(hex: 0x363954)
        static let i500 = Color(hex: 0x434767)
        static let i400 = Color(hex: 0x555A7E)
    }
    enum Lav {
        static let l500 = Color(hex: 0x8D99AE)
        static let l400 = Color(hex: 0xA6B0C1)
        static let l300 = Color(hex: 0xC2C9D5)
        static let l200 = Color(hex: 0xDEE2EA)
        static let l100 = Color(hex: 0xF1F3F7)
    }

    // ---- Semantic (dark = only theme) ----
    // Cards match the app itself: black face, white border. Depth comes from
    // the borders and spacing, not tonal fills.
    static let bg = Core.black
    static let card = Core.black
    static let cardBorder = Color.white
    static let cardOpen = Indigo.i800
    static let surface = Indigo.i700
    static let well = Indigo.i950
    static let ink = Core.white
    static let ink2 = Lav.l500
    static let ink3 = Indigo.i400
    static let rule = Color(hex: 0x8D99AE, alpha: 0.18)
    static let signal = Core.brightLemon
    static let signalPressed = Color(hex: 0xC6C31F)
    static let onSignal = Core.black
    static let grab = Core.white
    static let alert = Color(hex: 0xE85D4A)
    static let online = Color(hex: 0x30D158)

    // ---- Spacing (4pt grid) ----
    enum Space {
        static let s1: CGFloat = 4, s2: CGFloat = 8, s3: CGFloat = 12, s4: CGFloat = 16
        static let s5: CGFloat = 24, s6: CGFloat = 32, s7: CGFloat = 48, s8: CGFloat = 64
    }

    // ---- Radii (keys 6 · cards 14 · sheets 16; never rounder) ----
    enum Radius {
        static let key: CGFloat = 6, card: CGFloat = 14, sheet: CGFloat = 16
        static let pill: CGFloat = 28
    }
}
