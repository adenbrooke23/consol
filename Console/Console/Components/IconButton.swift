import SwiftUI

// The thin ×/← control used on cards and the chooser: 16pt glyph, ink2 →
// white on press, inside an invisible 44pt hit area. No fill, no border.
struct IconButton: View {
    var systemName: String
    var a11y: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .light))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressTintStyle())
        .accessibilityLabel(a11y)
    }
}

private struct PressTintStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(configuration.isPressed ? Theme.grab : Theme.ink2)
    }
}
