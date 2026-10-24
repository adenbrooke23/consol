import SwiftUI

// One card = one session. The card fill is true black (matches the stage), so
// the border is the card edge; never render a card without one:
//   idle    → hairline rule (lavender @18%)
//   live    → 1pt solid white
//   focused → 1.5pt solid white
//
// Resting cards are glance-only: art, title, subtitle, meter/clock.
// Focused cards pin the header (WHERE · KIND · ×) and art at the top and reveal
// kind-specific detailed controls in the card body, scrolling internally. Quick
// controls live in the bottom bar; deep controls live here, with no modals or
// sheets.

struct SessionCardView: View {
    @Binding var session: Session
    let focused: Bool
    let namespace: Namespace.ID
    var onTap: () -> Void
    var onClose: () -> Void

    @Environment(SessionStore.self) private var store
    @GestureState private var pressing = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s3) {
            header
            art
            if focused {
                focusedBody
            } else {
                restingBody
            }
        }
        .padding(Theme.Space.s4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(pressing && !focused ? Theme.well : Theme.bg)   // black; press → well
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .stroke(borderColor, lineWidth: borderWidth)   // the border is the edge
        )
        .animation(Theme.Motion.snappy, value: pressing)
        .contentShape(Rectangle())
        .onTapGesture { if !focused { onTap() } }               // focused body handles its own taps
        .simultaneousGesture(
            focused ? nil :
            DragGesture(minimumDistance: 0).updating($pressing) { _, s, _ in s = true }
        )
        .highPriorityGesture(
            focused ? nil :
            DragGesture(minimumDistance: 15)
                .onEnded { g in
                    if g.translation.height > 60, abs(g.translation.width) < 80 { requestEnd() }
                }
        )
        .accessibilityElement(children: focused ? .contain : .combine)
        .accessibilityLabel(focused ? "" : a11y)
        .accessibilityAddTraits(focused ? [] : .isButton)
        .accessibilityAction(named: "End session") { requestEnd() }
    }

    // MARK: Header: WHERE · KIND · ×  (pinned)
    private var header: some View {
        HStack(spacing: Theme.Space.s2) {
            Text(session.whereLabel).typo(.label).foregroundStyle(Theme.ink2)
            Spacer(minLength: 0)
            Text(session.kind.label)
                .font(.custom(FontStack.mono.regular, size: 9.5))
                .tracking(0.12 * 9.5)
                .foregroundStyle(Theme.ink3)
                .padding(.vertical, 3)
                .padding(.horizontal, 8)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.rule, lineWidth: 1))
            IconButton(systemName: "xmark", a11y: "End session", action: requestEnd)
                .padding(.trailing, -14)   // pull the 44pt hit area toward the corner
        }
    }

    // MARK: Art (pinned)
    @ViewBuilder private var art: some View {
        if session.kind.isVideo {
            RoundedRectangle(cornerRadius: Theme.Radius.key)
                .fill(ArtPalette.gradient(seed: session.artSeed))
                .aspectRatio(16.0 / 10.0, contentMode: .fit)
                // Resting: natural height so art (and all content below it) hugs
                // the top, aligned with the music card. Focused: cap at 180.
                .frame(maxHeight: focused ? 180 : nil, alignment: .top)
                .overlay(realArt)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.key))
                .matchedGeometryEffect(id: "art-\(session.id)", in: namespace)
        } else {
            HStack(alignment: .bottom, spacing: 0) {
                RoundedRectangle(cornerRadius: Theme.Radius.key)
                    .fill(ArtPalette.gradient(seed: session.artSeed))
                    .frame(width: focused ? 132 : 96, height: focused ? 132 : 96)
                    .overlay(realArt)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.key))
                    .matchedGeometryEffect(id: "art-\(session.id)", in: namespace)
                Spacer(minLength: 0)
                // Spotify attribution (brand guidelines): the icon marks
                // Spotify-sourced content; official asset, never restyled.
                if session.artURL != nil || session.trackURI != nil {
                    Image("SpotifyIcon")
                        .resizable().scaledToFit()
                        .frame(width: 24, height: 24)
                        .accessibilityLabel("Content from Spotify")
                }
            }
        }
    }

    // Real cover art (once something real plays) over the gradient placeholder.
    @ViewBuilder private var realArt: some View {
        if let urlString = session.artURL, let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                }  // gradient stays underneath while loading / on failure
            }
        }
    }

    // MARK: Resting (glance only)
    private var restingBody: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s3) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .typo(.cardTitle).foregroundStyle(Theme.ink).lineLimit(1)
                Text(session.subtitle)
                    .font(.custom(FontStack.ui.regular, size: 12.5))
                    .foregroundStyle(Theme.ink2).lineLimit(1)
            }
            Spacer(minLength: 0)
            footer
        }
    }

    // MARK: Focused (detailed controls in place)
    @ViewBuilder private var focusedBody: some View {
        switch session.kind {
        case .music:
            MusicDetailView(session: $session)
        case .liveTV, .film, .apps:
            VideoDetailView(session: $session)
        }
    }

    @ViewBuilder private var footer: some View {
        HStack(spacing: Theme.Space.s3) {
            switch session.kind {
            case .music:
                MeterView(live: session.isLive)
                Text(session.volumeDb).typo(.readoutS).foregroundStyle(Theme.ink2)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            case .liveTV:
                Text(session.isLive ? "LIVE" : "PAUSED").typo(.label)
                    .foregroundStyle(session.isLive ? Theme.signal : Theme.ink3)
                Text(session.subtitle).typo(.readoutS).foregroundStyle(Theme.ink2)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            case .film:
                Text(session.subtitle).typo(.readoutS).foregroundStyle(Theme.ink2)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            case .apps:
                Text(session.title).typo(.readoutS).foregroundStyle(Theme.ink2)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    // MARK: State
    private var borderColor: Color {
        if focused || session.isLive { return Theme.grab }   // white
        return Theme.rule
    }
    private var borderWidth: CGFloat { focused ? 1.5 : 1 }

    // Ending a TV session turns its TV off. The ask happens in the stage's
    // bottom-center capsule (where every message lives), not inside the card.
    private func requestEnd() {
        if session.needsEndConfirmation {
            withAnimation(Theme.Motion.snappy) { store.pendingEnd = session.id }
        } else {
            onClose()
        }
    }

    private var a11y: String {
        let live = session.isLive ? "live" : "idle"
        return "\(session.whereLabel), \(live) \(session.kind.label.lowercased()), \(session.title)"
    }
}
