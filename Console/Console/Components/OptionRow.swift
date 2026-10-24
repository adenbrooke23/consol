import SwiftUI

// Option row: icon + label on the black panel, optional mono status on the
// right, and a lemon check when multi-selected. Press raises to `surface`.
// Shared by the session chooser, Profile and other panels.
struct OptionRow: View {
    var icon: String
    var label: String
    var trailing: String?
    var trailingColor: Color
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.s3) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.ink2)
                    .frame(width: 28)
                Text(label)
                    .font(.custom(FontStack.ui.medium, size: 14))
                    .foregroundStyle(Theme.ink)
                Spacer(minLength: 0)
                if let trailing {
                    Text(trailing)
                        .font(.custom(FontStack.mono.regular, size: 9.5))
                        .tracking(0.1 * 9.5)
                        .foregroundStyle(trailingColor)
                }
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.signal)   // selection is live-state indication
                }
            }
            .padding(Theme.Space.s3)
            .contentShape(Rectangle())
        }
        .buttonStyle(OptionRowStyle(selected: selected))
    }
}

struct OptionRowStyle: ButtonStyle {
    var selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Theme.surface : .clear)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.key))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.key)
                    .stroke(selected ? Theme.ink2 : Theme.rule, lineWidth: 1)
            )
    }
}
