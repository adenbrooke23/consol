import SwiftUI

// Shared pieces. The house rule set: black cards with white borders, native
// Helvetica, sentence case, generous air. White fill marks the one primary
// action; everything else is a quiet outline or plain text.

struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).typo(.section).foregroundStyle(Theme.ink2)
    }
}

struct Card<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s4) {
            if let title { SectionLabel(title) }
            content
        }
        .padding(Theme.Space.s5 + 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .fill(Theme.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .strokeBorder(Theme.cardBorder, lineWidth: 1)
        )
    }
}

struct StatusDot: View {
    let color: Color
    var body: some View {
        Circle().fill(color).frame(width: 7, height: 7)
    }
}

/// White fill = the primary action; outline = secondary; danger = red text.
struct PillButton: View {
    enum Style { case grab, ghost, danger }
    let label: String
    var style: Style = .ghost
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.custom("HelveticaNeue-Medium", size: 13.5))
                .foregroundStyle(ink)
                .padding(.horizontal, Theme.Space.s4 + 2)
                .padding(.vertical, Theme.Space.s2 + 2)
                .background(Capsule().fill(fill))
                .overlay(Capsule().strokeBorder(stroke, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
    }

    private var ink: Color {
        switch style {
        case .grab: return Theme.onSignal
        case .ghost: return Theme.ink
        case .danger: return Theme.alert
        }
    }
    private var fill: Color { style == .grab ? Theme.grab : .clear }
    private var stroke: Color {
        switch style {
        case .grab: return .clear
        case .ghost: return Color.white.opacity(0.45)
        case .danger: return Theme.alert.opacity(0.45)
        }
    }
}

struct WellField: View {
    let label: String
    @Binding var text: String
    var secure = false
    var hint: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s2) {
            SectionLabel(label)
            Group {
                if secure {
                    SecureField("", text: $text)
                } else {
                    TextField("", text: $text)
                }
            }
            .textFieldStyle(.plain)
            .typo(.body)
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, Theme.Space.s3)
            .padding(.vertical, Theme.Space.s3 - 2)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.white.opacity(0.35), lineWidth: 1)
            )
            if let hint {
                Text(hint).typo(.caption).foregroundStyle(Theme.ink3)
            }
        }
    }
}

/// The lockup: hexagonal monogram over the name.
struct Wordmark: View {
    var compact = false
    var body: some View {
        VStack(spacing: compact ? Theme.Space.s3 : Theme.Space.s4) {
            Image("ConsolLogo")
                .resizable()
                .scaledToFit()
                .frame(width: compact ? 36 : 80)
            // The brand stays "CONSOL" in caps: it's the logotype, not a label.
            Text("CONSOL")
                .font(.custom(compact ? "HelveticaNeue-Medium" : "HelveticaNeue-Bold",
                              size: compact ? 19 : 30))
                .tracking(0.6)
                .foregroundStyle(Theme.ink)
        }
    }
}
