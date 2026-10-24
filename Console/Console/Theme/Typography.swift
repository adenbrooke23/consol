import SwiftUI

// Two faces, six roles. Fonts are bundled and registered at runtime (see
// FontRegistrar) and referenced by exact PostScript name.
//
// To swap typefaces, change only the two structs below; nothing else in the
// app names a font. Mono is used for values/labels/timecodes only, never
// sentences; a mono value in lemon means "live".

enum FontStack {
    struct UI { let regular, medium, semibold, bold: String }
    struct Mono { let light, regular, medium, bold: String }

    static let ui = UI(
        regular: "GeneralSans-Regular",
        medium: "GeneralSans-Medium",
        semibold: "GeneralSans-Semibold",
        bold: "GeneralSans-Bold"
    )
    static let mono = Mono(
        light: "MartianMono-Light",
        regular: "MartianMono-Regular",
        medium: "MartianMono-Medium",
        bold: "MartianMono-Bold"
    )
}

// Six roles from the spec. Each carries its font, tracking (in points at its
// size), line spacing, and case.
enum Typo {
    case display, title, cardTitle, body, readoutL, readoutS, label

    var font: Font {
        switch self {
        case .display:  return .custom(FontStack.ui.bold, size: 56)
        case .title:    return .custom(FontStack.ui.semibold, size: 28)
        case .cardTitle:return .custom(FontStack.ui.medium, size: 15)
        case .body:     return .custom(FontStack.ui.regular, size: 16)
        case .readoutL: return .custom(FontStack.mono.light, size: 34)
        case .readoutS: return .custom(FontStack.mono.regular, size: 12)
        case .label:    return .custom(FontStack.mono.medium, size: 11)
        }
    }

    // tracking = em × size, in points
    var tracking: CGFloat {
        switch self {
        case .display:  return -0.02 * 56
        case .title:    return -0.01 * 28
        case .readoutL: return 0.02 * 34
        case .readoutS: return 0.02 * 12
        case .label:    return 0.18 * 11
        default:        return 0
        }
    }

    var lineSpacing: CGFloat {
        switch self {
        case .title: return 6   // 28/34
        case .body:  return 8   // 16/24
        default:     return 0
        }
    }

    var uppercased: Bool { self == .label }
    var supportsDynamicType: Bool { self == .body || self == .cardTitle }
}

private struct TypoModifier: ViewModifier {
    let role: Typo
    func body(content: Content) -> some View {
        content
            .font(role.font)
            .tracking(role.tracking)
            .lineSpacing(role.lineSpacing)
            .textCase(role.uppercased ? .uppercase : nil)
    }
}

extension View {
    /// Apply a type role. Color is applied separately via foregroundStyle.
    func typo(_ role: Typo) -> some View { modifier(TypoModifier(role: role)) }
}
