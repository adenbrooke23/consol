import SwiftUI

// The dashed "+" card. Two sizes: the empty-state hero (240×220) and the
// trailing slot in a populated row (120 wide). The dash "breathes" slowly
// (paused under Reduce Motion, and while hovered/pressed). Tapping it opens the
// creation chooser.

struct NewSessionCard: View {
    enum Size { case hero, trailing }
    var size: Size
    var onTap: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathe = false
    @State private var pressed = false

    private var plusDiameter: CGFloat { size == .hero ? 52 : 40 }

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: Theme.Space.s3) {
                ZStack {
                    Circle().stroke(Color.currentDash, lineWidth: 1.5)
                    Image(systemName: "plus")
                        .font(.system(size: size == .hero ? 22 : 18, weight: .light))
                        .foregroundStyle(Theme.ink3)
                }
                .frame(width: plusDiameter, height: plusDiameter)

                if size == .hero {
                    Text("New session").typo(.label).foregroundStyle(Theme.ink3)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.card)
                    .strokeBorder(
                        Theme.ink3.opacity(breathe ? 0.85 : 0.55),
                        style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) {
                breathe = true
            }
        }
        .accessibilityLabel("New session")
        .accessibilityHint("Opens the session chooser")
    }
}

private extension Color {
    // The + ring uses ink3; kept here so the breathe stroke can reference it.
    static var currentDash: Color { Theme.ink3 }
}
