import SwiftUI

// Full-screen now-playing takeover. Same room and state, bigger canvas:
// album art left, readout + transport right, black stays black. Spotify
// attribution per brand guidelines (icon; the full logo lives on Profile).
// Content sits centered without filling the screen.
// × top-right (or the bar's collapse glyph) returns to the stage.

struct NowPlayingView: View {
    let session: Session
    @Environment(SessionStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var motion: Animation? { reduceMotion ? nil : Theme.Motion.snappy }

    private var playing: Binding<Bool> {
        Binding(get: { session.isLive }, set: { _ in store.togglePlay(session.id) })
    }

    /// The queue entry after the current one, shown as the single "up next" readout.
    private var nextUp: QueueItem? {
        guard let music = session.music else { return nil }
        guard let pos = music.queuePosition else { return music.queue.first }
        return music.queue.first { $0.position > pos }
    }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()

            HStack(spacing: Theme.Space.s7) {
                // Album art: original form, 8pt corners (Spotify spec for
                // large canvases), gradient placeholder underneath.
                RoundedRectangle(cornerRadius: 8)
                    .fill(ArtPalette.gradient(seed: session.artSeed))
                    .frame(width: 380, height: 380)
                    .overlay {
                        if let urlString = session.artURL, let url = URL(string: urlString) {
                            AsyncImage(url: url) { phase in
                                if let image = phase.image {
                                    image.resizable().scaledToFill()
                                }
                            }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: Theme.Space.s4) {
                    Text("PLAYING ON \(session.whereLabel.uppercased())")
                        .font(.custom(FontStack.mono.regular, size: 9.5))
                        .tracking(0.12 * 9.5)
                        .foregroundStyle(Theme.ink3)

                    VStack(alignment: .leading, spacing: Theme.Space.s1) {
                        Text(session.title)
                            .font(.custom(FontStack.ui.semibold, size: 28))
                            .foregroundStyle(Theme.ink)
                            .lineLimit(2)
                        Text(session.subtitle)
                            .font(.custom(FontStack.ui.regular, size: 16))
                            .foregroundStyle(Theme.ink2)
                            .lineLimit(1)
                    }

                    Image("SpotifyIcon")
                        .resizable().scaledToFit()
                        .frame(width: 22, height: 22)
                        .accessibilityLabel("Content from Spotify")

                    if session.hasPlaybackContext { scrubCluster }

                    HStack(spacing: Theme.Space.s3) {
                        GlyphButton(systemName: "backward.end.fill", a11y: "Previous") {
                            store.previousTrack(session.id)
                        }
                        PlaySquircle(playing: playing)
                        GlyphButton(systemName: "forward.end.fill", a11y: "Next") {
                            store.nextTrack(session.id)
                        }
                    }
                    .padding(.top, Theme.Space.s1)

                    if let next = nextUp {
                        VStack(alignment: .leading, spacing: Theme.Space.s1) {
                            Text("UP NEXT")
                                .font(.custom(FontStack.mono.regular, size: 9.5))
                                .tracking(0.12 * 9.5)
                                .foregroundStyle(Theme.ink3)
                            Text("\(next.title) · \(next.artist)")
                                .font(.custom(FontStack.ui.regular, size: 13.5))
                                .foregroundStyle(Theme.ink2)
                                .lineLimit(1)
                        }
                        .padding(.top, Theme.Space.s2)
                    }
                }
                .frame(maxWidth: 430, alignment: .leading)
            }
            .padding(Theme.Space.s7)
        }
        .overlay(alignment: .topTrailing) {
            IconButton(systemName: "xmark", a11y: "Close full screen") {
                withAnimation(motion) { store.fullscreen = nil }
            }
            .padding(Theme.Space.s4)
        }
        // The session ended while in full screen: nothing to show.
        .onChange(of: store.sessions.map(\.id).contains(session.id)) { _, stillHere in
            if !stillHere { store.fullscreen = nil }
        }
    }

    // Elapsed · scrubber · duration: the same cluster as the transport bar,
    // stretched to the readout column. Drag seeks the real track.
    private var scrubCluster: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            HStack(spacing: Theme.Space.s2) {
                Text(session.elapsedLabel)
                    .typo(.readoutS).foregroundStyle(Theme.ink2)
                    .monospacedDigit().lineLimit(1).fixedSize()
                    .frame(minWidth: 36, alignment: .trailing)
                ElasticBar(value: Binding(
                    get: { session.elapsedFraction },
                    set: { store.seek(session.id, to: $0) }
                ))
                .accessibilityLabel("Track position")
                Text(session.durationLabel)
                    .typo(.readoutS).foregroundStyle(Theme.ink3)
                    .monospacedDigit().lineLimit(1).fixedSize()
                    .frame(minWidth: 36, alignment: .leading)
            }
        }
        .accessibilityLabel("Elapsed \(session.elapsedLabel) of \(session.durationLabel)")
    }
}
