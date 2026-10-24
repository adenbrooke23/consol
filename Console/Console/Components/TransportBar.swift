import SwiftUI

// The persistent bottom transport bar, docked directly above the status strip.
// It reflects the bar-context session (store.barSession), which is the last
// card the user touched, and holds the always-reachable quick controls.
//
//  • nothing selected → slim idle state ("NOTHING SELECTED").
//  • a card is expanded (barCollapsed) → the bar collapses to art + title,
//    because the focused card body already carries the controls.
//  • otherwise → full, kind-specific quick controls.
//
// Switching context (tapping another card) cross-fades with .snappy(0.25).

struct TransportBar: View {
    @Environment(SessionStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var swap: Animation? { reduceMotion ? nil : Theme.Motion.barSwap }

    var body: some View {
        content
            .frame(maxWidth: .infinity)
            .frame(height: 68)
            .padding(.horizontal, Theme.Space.s5)
            .background(Theme.bg)
            .overlay(alignment: .top) { Rectangle().fill(Theme.rule).frame(height: 1) }
            .animation(swap, value: store.barID)
            .animation(swap, value: store.barCollapsed)
    }

    @ViewBuilder private var content: some View {
        if let session = store.barSession {
            // Always show full transport: the focused card body doesn't carry
            // prev/play/next, so the bar stays the one place playback lives.
            FullBar(session: session)
                .id("full-\(session.id)")
                .transition(.opacity)
        } else {
            idle
        }
    }

    private var idle: some View {
        HStack {
            Text("NOTHING SELECTED").typo(.label).foregroundStyle(Theme.ink3)
            Spacer(minLength: 0)
        }
    }
}

// MARK: Collapsed: art + title only (the focused card body owns the controls)
private struct CollapsedBar: View {
    let session: Session
    var body: some View {
        HStack(spacing: Theme.Space.s3) {
            ArtThumb(seed: session.artSeed, kind: session.kind, side: 40)
            titleBlock(session)
            Spacer(minLength: 0)
            Text(session.whereLabel).typo(.label).foregroundStyle(Theme.ink2)
        }
    }
}

// MARK: Full: kind-specific quick controls
private struct FullBar: View {
    @Environment(SessionStore.self) private var store
    let session: Session
    @State private var readoutLive = false
    /// Routing mode: the bar's middle swaps to speaker chips so the room mix
    /// is switchable from anywhere without digging past search results.
    @State private var routing = false
    /// Chip taps switch rooms by default; the link toggle opts into grouping
    /// (a deliberate decision, never automatic).
    @State private var grouping = false

    private var playing: Binding<Bool> {
        Binding(get: { session.isLive }, set: { _ in store.togglePlay(session.id) })
    }
    private var volume: Binding<Double> {
        Binding(get: { session.volume }, set: { store.setVolume(session.id, $0) })
    }
    private var scrub: Binding<Double> {
        Binding(get: { session.progress }, set: { store.setProgress(session.id, $0) })
    }

    var body: some View {
        HStack(spacing: Theme.Space.s4) {
            HStack(spacing: Theme.Space.s3) {
                ArtThumb(seed: session.artSeed, kind: session.kind, side: 44,
                         imageURL: session.artURL)
                titleBlock(session)
            }
            .frame(width: 220, alignment: .leading)

            if routing {
                routingStrip
            } else {
                transport

                Spacer(minLength: Theme.Space.s4)

                if session.kind != .apps { volumeCluster }

                whereControl

                if session.kind == .music, session.hasPlaybackContext {
                    // Full-screen now-playing takeover for this session.
                    GlyphButton(systemName: "arrow.up.left.and.arrow.down.right",
                                a11y: "Full screen") {
                        withAnimation(Theme.Motion.snappy) {
                            store.fullscreen = session.id
                        }
                    }
                }
            }
        }
        .animation(Theme.Motion.barSwap, value: routing)
        .onChange(of: session.id) { _, _ in routing = false }
    }

    // The WHERE readout. For music it's a control: tap to swap the bar into
    // routing mode (same label face, no new chrome).
    @ViewBuilder private var whereControl: some View {
        if session.kind == .music {
            Button {
                withAnimation(Theme.Motion.barSwap) { routing = true }
            } label: {
                Text(session.whereLabel).typo(.label).foregroundStyle(Theme.ink2)
                    .frame(minWidth: 80, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Playing on \(session.whereLabel). Change rooms")
        } else {
            Text(session.whereLabel).typo(.label).foregroundStyle(Theme.ink2)
                .frame(minWidth: 80, alignment: .trailing)
        }
    }

    // In-place room mix: the same chips as the card's Speakers section.
    // Default tap = straight switch; the link toggle arms group mode.
    private var routingStrip: some View {
        HStack(spacing: Theme.Space.s3) {
            Text(grouping ? "GROUP" : "SWITCH").typo(.label).foregroundStyle(Theme.ink3)
                .frame(minWidth: 52, alignment: .trailing)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Space.s2) {
                    ForEach(store.outputs.filter { $0.kind == .speaker }) { output in
                        SpeakerChip(
                            name: output.name,
                            inGroup: session.speakerNames.contains(output.name),
                            live: session.isLive && session.speakerNames.contains(output.name)
                        ) {
                            if grouping {
                                store.toggleGroupMember(session.id, output.name)
                            } else {
                                store.switchRoom(session.id, to: output.name)
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            GlyphToggle(onName: "link", isOn: grouping,
                        a11y: "Group mode") { grouping.toggle() }
            IconButton(systemName: "xmark", a11y: "Done changing rooms") {
                withAnimation(Theme.Motion.barSwap) { routing = false; grouping = false }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(.opacity)
    }

    @ViewBuilder private var transport: some View {
        switch session.kind {
        case .music:
            HStack(spacing: Theme.Space.s2) {
                GlyphButton(systemName: "backward.end.fill", a11y: "Previous") {
                    store.previousTrack(session.id)
                }
                PlaySquircle(playing: playing)
                GlyphButton(systemName: "forward.end.fill", a11y: "Next") {
                    store.nextTrack(session.id)
                }
                if session.hasPlaybackContext { trackScrubCluster }
            }
        case .liveTV, .film, .apps:
            // One transport for every TV kind; they all drive the same box.
            // Skip and scrub only appear once the TV reports a real player,
            // and only if the app on screen honours them: an app that ignores
            // the command shouldn't get a button that does nothing.
            HStack(spacing: Theme.Space.s3) {
                dpadAffordance
                if session.tvHasPlayer && session.tvCanSkip {
                    GlyphButton(systemName: "gobackward.10", a11y: "Back 10 seconds") {
                        store.skipTV(session.id, seconds: -10)
                    }
                }
                PlaySquircle(playing: playing, showsPausedState: true)
                if session.tvHasPlayer && session.tvCanSkip {
                    GlyphButton(systemName: "goforward.10", a11y: "Forward 10 seconds") {
                        store.skipTV(session.id, seconds: 10)
                    }
                }
                if session.tvHasPlayer { tvScrubCluster }
            }
        }
    }

    // Elapsed · position · running time, straight off the TV.
    private var tvScrubCluster: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            HStack(spacing: Theme.Space.s2) {
                Text(session.elapsedLabel)
                    .typo(.readoutS).foregroundStyle(Theme.ink2)
                    .monospacedDigit().lineLimit(1).fixedSize()
                    .frame(minWidth: 40, alignment: .trailing)
                // Always draggable once there's a player. A refusal is
                // momentary (ads), not a capability, so the reported seek
                // flag doesn't gate it.
                ElasticBar(value: Binding(
                    get: { session.elapsedFraction },
                    set: { store.seekTV(session.id, to: $0) }
                ))
                .frame(width: 150)
                .accessibilityLabel("Playback position")
                Text(session.durationLabel)
                    .typo(.readoutS).foregroundStyle(Theme.ink3)
                    .monospacedDigit().lineLimit(1).fixedSize()
                    .frame(minWidth: 40, alignment: .leading)
            }
        }
        .accessibilityLabel("Elapsed \(session.elapsedLabel) of \(session.durationLabel)")
    }

    private var dpadAffordance: some View {
        // Compact D-pad affordance: focuses the card AND opens its
        // companion remote card.
        Button {
            withAnimation(Theme.Motion.focus) {
                if store.focusedID != session.id { store.toggleFocus(session.id) }
                store.remoteFor = session.id
            }
        } label: {
            Image(systemName: "dpad")
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(Theme.ink)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open remote")
    }

    // Elapsed · scrubber · duration, ticking once a second while playing
    // (frozen on pause; the per-room poll re-syncs to the speaker's real
    // position). Dragging the bar seeks the actual track (debounced in the
    // store). Only exists once the session carries real playback.
    private var trackScrubCluster: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            HStack(spacing: Theme.Space.s2) {
                Text(session.elapsedLabel)
                    .typo(.readoutS)
                    .foregroundStyle(Theme.ink2)
                    .monospacedDigit()
                    .lineLimit(1).fixedSize()   // long times widen, never wrap
                    .frame(minWidth: 36, alignment: .trailing)
                ElasticBar(value: Binding(
                    get: { session.elapsedFraction },
                    set: { store.seek(session.id, to: $0) }
                ))
                .frame(width: 150)
                .accessibilityLabel("Track position")
                Text(session.durationLabel)
                    .typo(.readoutS)
                    .foregroundStyle(Theme.ink3)
                    .monospacedDigit()
                    .lineLimit(1).fixedSize()
                    .frame(minWidth: 36, alignment: .leading)
            }
        }
        .padding(.leading, Theme.Space.s2)
        .accessibilityLabel("Elapsed \(session.elapsedLabel) of \(session.durationLabel)")
    }

    private var volumeCluster: some View {
        HStack(spacing: Theme.Space.s3) {
            Image(systemName: "speaker.wave.2")
                .font(.system(size: 14)).foregroundStyle(Theme.ink3)
            ElasticBar(value: volume) { readoutLive = $0 }
                .frame(width: 160)
            Text(session.volumeDb)
                .typo(.readoutS)
                .foregroundStyle(readoutLive ? Theme.signal : Theme.ink2)   // lemon while live
                .frame(width: 44, alignment: .trailing)
                .monospacedDigit()
        }
    }

    private var channelLabel: String {
        session.subtitle.split(separator: " ").first.map(String.init) ?? "—"
    }
}

// Shared title/subtitle block.
private func titleBlock(_ session: Session) -> some View {
    VStack(alignment: .leading, spacing: 1) {
        Text(session.title)
            .font(.custom(FontStack.ui.medium, size: 14))
            .foregroundStyle(Theme.ink)
            .lineLimit(1)
        Text(session.subtitle)
            .font(.custom(FontStack.ui.regular, size: 12))
            .foregroundStyle(Theme.ink2)
            .lineLimit(1)
    }
}
