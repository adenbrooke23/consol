import SwiftUI

// Design tokens, taken 1:1 from docs/design/style-guide.html.
// Product model: sessions as cards on a black stage. Dark is the only theme.
//
// Three standing rules the whole system enforces:
//  • Signal: brightLemon is indication only (meters, live dots, focus, live
//    readouts, the online dot). Never a fill on a control face; ≤3% of a screen.
//  • Touch: solid white marks only what you grab. Nothing else is solid white.
//  • Stage: the canvas is true black; depth is tonal steps + hairlines, never
//    shadows/gradients/blur (art placeholders are the sole gradient exception).

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
    static let bg = Core.black             // the stage, edge to edge
    static let card = Indigo.i900          // resting session card
    static let cardOpen = Indigo.i800      // focused / hovered card, chooser
    static let surface = Indigo.i700       // sheets, panels
    static let well = Indigo.i950          // recessed: fields, bar rails, PIN boxes
    static let ink = Core.white
    static let ink2 = Lav.l500
    static let ink3 = Indigo.i400
    static let rule = Color(hex: 0x8D99AE, alpha: 0.18) // hairlines (every card on black needs one)
    static let signal = Core.brightLemon
    static let signalPressed = Color(hex: 0xC6C31F)
    static let onSignal = Core.black        // ink on signal is always black
    static let grab = Core.white            // "what you grab"; nothing else is solid white
    static let alert = Color(hex: 0xE85D4A) // offline / PIN error / device busy; the one off-palette color
    static let online = Color(hex: 0x30D158) // hub-online dot only; the only place green appears

    // ---- Spacing (4pt grid) ----
    enum Space {
        static let s1: CGFloat = 4, s2: CGFloat = 8, s3: CGFloat = 12, s4: CGFloat = 16
        static let s5: CGFloat = 24, s6: CGFloat = 32, s7: CGFloat = 48, s8: CGFloat = 64
    }

    // ---- Radii (keys 6 · cards 14 · sheets 16; never rounder) ----
    // pill (28) is the one sanctioned exception, for chooser-style panels.
    enum Radius {
        static let key: CGFloat = 6, card: CGFloat = 14, sheet: CGFloat = 16
        static let pill: CGFloat = 28
    }

    // ---- Motion (springs, bounce ≤0.15) ----
    enum Motion {
        static let focus = Animation.spring(duration: 0.45, bounce: 0.12)
        static let birth = Animation.spring(duration: 0.40, bounce: 0.15)
        static let tabExpand = Animation.spring(duration: 0.35, bounce: 0.15)
        static let tabCollapse = Animation.spring(duration: 0.30, bounce: 0)
        static let press = Animation.spring(response: 0.15, dampingFraction: 0.6)
        static let snappy = Animation.snappy(duration: 0.30)
        static let barSwap = Animation.snappy(duration: 0.25)   // bottom-bar context switch
        static let stack = Animation.spring(duration: 0.40, bounce: 0.10) // chooser collapse/expand
        static let elastic = Animation.spring(response: 0.25, dampingFraction: 0.75) // rail grow/exhale
    }
}
