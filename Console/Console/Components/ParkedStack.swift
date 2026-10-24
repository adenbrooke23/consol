import SwiftUI

// When the chooser opens, the live session cards collapse into this overlapping
// pile so the chooser always has room and never runs off the right edge. The
// stack reads as one object ("N sessions parked"), but every spine keeps its
// meter live: collapsing is purely visual, never a playback pause.
//
// Most-recent session sits on top; each lower spine reveals a 12pt sliver.

struct ParkedStack: View {
    let sessions: [Session]
    var namespace: Namespace.ID

    private let spineWidth: CGFloat = 64
    private let reveal: CGFloat = 12

    /// Total footprint so the parent can size the freed space for the chooser.
    static func width(count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        return 64 + CGFloat(count - 1) * 12
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s3) {
            ZStack(alignment: .topLeading) {
                ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                    CardSpine(session: session)
                        .matchedGeometryEffect(id: "card-\(session.id)", in: namespace)
                        .frame(width: spineWidth)
                        .offset(x: CGFloat(index) * reveal)
                        .zIndex(Double(index))            // most-recent on top
                }
            }
            .frame(width: ParkedStack.width(count: sessions.count))
            .frame(maxHeight: .infinity, alignment: .topLeading)

            Text("\(sessions.count) \(sessions.count == 1 ? "session" : "sessions") parked")
                .typo(.label)
                .foregroundStyle(Theme.ink3)
                .fixedSize()
        }
    }
}

// A collapsed card: a 64pt spine. Border carries live state (white = live) just
// like the full card; the meter keeps animating so the pile clearly reads as
// still-playing.
struct CardSpine: View {
    let session: Session

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s3) {
            RoundedRectangle(cornerRadius: Theme.Radius.key)
                .fill(ArtPalette.gradient(seed: session.artSeed))
                .frame(width: 40, height: 40)

            Text(session.title)
                .font(.custom(FontStack.ui.medium, size: 11))
                .foregroundStyle(Theme.ink)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            liveIndicator
        }
        .padding(Theme.Space.s2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.bg)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .stroke(session.isLive ? Theme.grab : Theme.rule,
                        lineWidth: session.isLive ? 1 : 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(session.title), parked, \(session.isLive ? "playing" : "idle")")
    }

    @ViewBuilder private var liveIndicator: some View {
        switch session.kind {
        case .music:
            MeterView(live: session.isLive, bars: 4, height: 14)
        case .liveTV:
            Text("LIVE").typo(.label).foregroundStyle(session.isLive ? Theme.signal : Theme.ink3)
        case .film, .apps:
            MeterView(live: session.isLive && session.kind == .film, bars: 4, height: 14)
        }
    }
}
