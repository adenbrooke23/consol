import SwiftUI

// Native type: Helvetica Neue, straight from the system. No bundled fonts, no
// decorative mono, no tracking tricks, sentence case everywhere. The one
// exception is `console`: the live install log is tabular output, so it uses
// Menlo.

enum Typo {
    case display     // wizard page headlines
    case title       // window/app headers
    case section     // card titles ("Household")
    case body        // sentences, fields
    case value       // right-aligned facts ("2 ms", "Running")
    case caption     // quiet footnotes
    case console     // the install log only

    var font: Font {
        switch self {
        case .display: return .custom("HelveticaNeue-Bold", size: 34)
        case .title:   return .custom("HelveticaNeue-Medium", size: 20)
        case .section: return .custom("HelveticaNeue-Medium", size: 13)
        case .body:    return .custom("HelveticaNeue", size: 15)
        case .value:   return .custom("HelveticaNeue-Medium", size: 15)
        case .caption: return .custom("HelveticaNeue", size: 12.5)
        case .console: return .custom("Menlo-Regular", size: 11.5)
        }
    }

    var tracking: CGFloat {
        switch self {
        case .display: return -0.4
        case .title:   return -0.2
        default:       return 0
        }
    }

    var lineSpacing: CGFloat {
        switch self {
        case .body:    return 5
        case .caption: return 4
        case .console: return 2
        default:       return 0
        }
    }
}

private struct TypoModifier: ViewModifier {
    let role: Typo
    func body(content: Content) -> some View {
        content
            .font(role.font)
            .tracking(role.tracking)
            .lineSpacing(role.lineSpacing)
    }
}

extension View {
    func typo(_ role: Typo) -> some View { modifier(TypoModifier(role: role)) }
}
