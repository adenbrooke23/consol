import SwiftUI

// Bare-glyph transport. The play/pause squircle is the one solid-white control
// (you grab it); prev/next/back-10 are bare drawn glyphs in ink. Play↔pause
// morphs in place via the symbol replace effect. Never text glyphs.

struct PlaySquircle: View {
    @Binding var playing: Bool
    var size: CGFloat = 44
    /// TV sessions: a paused screen goes lemon so it reads across the room.
    /// The glyph itself carries the meaning (play when paused, pause when
    /// playing), so there is no label; lemon is just the state tint.
    var showsPausedState: Bool = false
    var onToggle: (() -> Void)? = nil

    private var paused: Bool { showsPausedState && !playing }

    var body: some View {
        Button {
            playing.toggle()
            onToggle?()
        } label: {
            squircle
        }
        .buttonStyle(.plain)
        .accessibilityLabel(playing ? "Pause" : "Play")
        .accessibilityValue(paused ? "Paused" : "")
    }

    private var squircle: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .fill(paused ? Theme.signal : Theme.grab)   // lemon = paused, white = grab
            Image(systemName: playing ? "pause.fill" : "play.fill")
                .font(.system(size: size * 0.42, weight: .medium))
                .foregroundStyle(paused ? Theme.onSignal : Theme.bg)
                .contentTransition(.symbolEffect(.replace))
        }
        .frame(width: size, height: size)
        .animation(Theme.Motion.snappy, value: paused)
    }
}

// A bare transport glyph (prev / next / back-10 …). Ink by default; presses
// tint white. No fill, no border.
struct GlyphButton: View {
    var systemName: String
    var a11y: String
    var size: CGFloat = 20
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .regular))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(GlyphPressStyle())
        .accessibilityLabel(a11y)
    }
}

private struct GlyphPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(configuration.isPressed ? Theme.grab : Theme.ink)
    }
}

// A bare glyph toggle that goes lemon when on (like/shuffle/repeat). These are
// live-state markers, so lemon is legal here; ink2 when off. Face never fills.
struct GlyphToggle: View {
    var onName: String
    var offName: String
    var isOn: Bool
    var a11y: String
    var size: CGFloat = 18
    var action: () -> Void

    init(onName: String, offName: String? = nil, isOn: Bool, a11y: String,
         size: CGFloat = 18, action: @escaping () -> Void) {
        self.onName = onName
        self.offName = offName ?? onName
        self.isOn = isOn
        self.a11y = a11y
        self.size = size
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: isOn ? onName : offName)
                .font(.system(size: size, weight: .regular))
                .foregroundStyle(isOn ? Theme.signal : Theme.ink2)   // lemon on, ink2 off
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(a11y)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }
}
