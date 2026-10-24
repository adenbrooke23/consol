import SwiftUI

// The home stage. Empty = one breathing + card + a background hint. Populated =
// a horizontal row of session cards, the + card trailing, a status strip
// pinned to the bottom. Tapping + swaps the slot for the chooser in place.
// One focused card at a time; cards are born (scale-in) and die (drop + fade).

struct StageView: View {
    @Environment(SessionStore.self) private var store
    @Environment(AuthStore.self) private var auth
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var ns
    @Namespace private var cardNS
    @State private var creating = false

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if store.isEmpty && !creating { emptyStage }
                else if creating { creatingStage }
                else { populatedStage }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            TransportBar()

            StatusStrip(
                hubOnline: store.hubOnline,
                sessionCount: store.sessions.count,
                profileName: auth.currentProfile?.name ?? "—"
            )
        }
        .background(Theme.bg.ignoresSafeArea())
        .overlay(alignment: .bottom) { noticeCapsule }
        .onAppear {
            if store.debugAutoOpenChooser { creating = true }
            #if DEBUG
            // Drive a real play attempt (app → hub → speaker) for testing.
            if let uri = ProcessInfo.processInfo.environment["UITEST_PLAY_URI"],
               let barID = store.barID {
                store.playResult(barID, SearchResult(
                    shape: .track, title: "Test Track", subtitle: "UITEST",
                    artSeed: 0, uri: uri))
            }
            #endif
        }
        // (The player poll + house load live on RootShellView: the stage is
        // unmounted whenever another tab is selected on iPad, and playback
        // state must keep flowing regardless of tab.)
        .task(id: store.notice) {
            guard store.notice != nil else { return }
            #if DEBUG
            if ProcessInfo.processInfo.environment["UITEST_NOTICE_HOLD"] == "1" { return }
            #endif
            try? await Task.sleep(for: .seconds(2.4))
            withAnimation(stackMotion) { store.notice = nil }
        }
    }

    // The one stage-level toast: lemon capsule = confirmation, alert = error.
    // A pending end-confirm takes the same slot, so questions and messages
    // live in one place, bottom center.
    @ViewBuilder private var noticeCapsule: some View {
        if let id = store.pendingEnd,
           let ending = store.sessions.first(where: { $0.id == id }) {
            HStack(spacing: Theme.Space.s4) {
                // Name the target: with two TV cards up, an unnamed question
                // plus a single pending slot could make Turn Off black out
                // the screen the user wasn't looking at.
                Text(ending.kind == .music
                     ? "END SESSION?"
                     : "TURN OFF \(ending.whereLabel.uppercased())?")
                    .font(.custom(FontStack.mono.medium, size: 10))
                    .tracking(0.1 * 10)
                    .foregroundStyle(Theme.onSignal)
                    .lineLimit(1)
                Button("KEEP") {
                    withAnimation(stackMotion) { store.pendingEnd = nil }
                }
                .font(.custom(FontStack.mono.medium, size: 10))
                .foregroundStyle(Theme.onSignal)
                Button {
                    withAnimation(stackMotion) {
                        store.pendingEnd = nil
                        store.end(id)
                    }
                } label: {
                    Text(ending.kind == .music ? "END" : "TURN OFF")
                        .font(.custom(FontStack.mono.medium, size: 10))
                        .tracking(0.1 * 10)
                        .foregroundStyle(Theme.onSignal)
                        .padding(.vertical, 6)
                        .padding(.horizontal, Theme.Space.s3)
                        .background(Theme.grab)          // white chip = the grab
                        .clipShape(Capsule())
                }
            }
            .buttonStyle(.plain)
            .padding(.vertical, Theme.Space.s2)
            .padding(.leading, Theme.Space.s4)
            .padding(.trailing, Theme.Space.s2)
            .background(Theme.signal)
            .clipShape(Capsule())
            .frame(maxWidth: 560)
            .padding(.bottom, 108)   // clears the transport bar + status strip
            .transition(.opacity)
        } else if let notice = store.notice {
            Text(notice.text)
                .font(.custom(FontStack.mono.medium, size: 10))
                .tracking(0.1 * 10)
                .foregroundStyle(notice.isError ? Theme.ink : Theme.onSignal)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.vertical, Theme.Space.s2)
                .padding(.horizontal, Theme.Space.s3)
                .background(notice.isError ? Theme.alert : Theme.signal)
                .clipShape(Capsule())
                .frame(maxWidth: 560)
                .padding(.bottom, 108)   // clears the transport bar + status strip
                .transition(.opacity)
        }
    }

    // MARK: Empty
    private var emptyStage: some View {
        ZStack {
            NewSessionCard(size: .hero, onTap: openChooser)
                .frame(width: 240, height: 220)
            VStack {
                Spacer()
                Text("Tap to play something, anywhere in the house")
                    .typo(.label)
                    .foregroundStyle(Theme.ink3)
                    .padding(.bottom, Theme.Space.s6)
            }
        }
        .padding(Theme.Space.s5)
    }

    // MARK: Populated row
    private var populatedStage: some View {
        ScrollViewReader { proxy in
            populatedScroll
                // Opening the browse card scrolls it fully into view.
                .onChange(of: store.browse) { _, target in
                    guard target != nil else { return }
                    withAnimation(stackMotion) {
                        proxy.scrollTo("browse", anchor: .trailing)
                    }
                }
                // Same for the remote card.
                .onChange(of: store.remoteFor) { _, id in
                    guard id != nil else { return }
                    withAnimation(stackMotion) {
                        proxy.scrollTo("remote", anchor: .trailing)
                    }
                }
                // Browse already open on appear (relaunch / debug hooks).
                .task {
                    guard store.browse != nil else { return }
                    try? await Task.sleep(for: .milliseconds(400))
                    withAnimation(stackMotion) {
                        proxy.scrollTo("browse", anchor: .trailing)
                    }
                }
        }
    }

    private var populatedScroll: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Space.s4) {
                ForEach(store.sessions) { session in
                    SessionCardView(
                        session: store.binding(session.id),
                        focused: store.isFocused(session.id),
                        namespace: ns,
                        onTap: { focus(session.id) },
                        onClose: { close(session.id) }
                    )
                    .frame(width: store.isFocused(session.id) ? 560 : 240)
                    .matchedGeometryEffect(id: "card-\(session.id)", in: cardNS)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.85).combined(with: .opacity),
                        removal: .move(edge: .bottom).combined(with: .opacity)
                    ))

                    // Companion browse card, docked beside the focused card.
                    if store.isFocused(session.id), let target = store.browse {
                        BrowseCardView(target: target, session: session)
                            .frame(width: 400)
                            .id("browse")
                            .transition(.asymmetric(
                                insertion: .scale(scale: 0.9).combined(with: .opacity),
                                removal: .opacity
                            ))
                    }

                    // Companion remote card, same contract as browse.
                    if store.isFocused(session.id), store.remoteFor == session.id {
                        RemoteCardView(session: session)
                            .frame(width: 300)
                            .id("remote")
                            .transition(.asymmetric(
                                insertion: .scale(scale: 0.9).combined(with: .opacity),
                                removal: .opacity
                            ))
                    }
                }
                NewSessionCard(size: store.isEmpty ? .hero : .trailing, onTap: openChooser)
                    .frame(width: store.isEmpty ? 240 : 120)
            }
            .padding(Theme.Space.s5)
            .frame(maxHeight: .infinity)
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
    }

    // MARK: Creating: cards collapse into a parked stack (left), chooser
    // expands into the freed space (right). Parked cards keep playing; the
    // collapse is purely visual. The chooser never runs off the right edge.
    private var creatingStage: some View {
        HStack(spacing: 0) {
            if !store.sessions.isEmpty {
                ParkedStack(sessions: store.sessions, namespace: cardNS)
            }
            Spacer(minLength: Theme.Space.s5)
            SessionChooserView(onCancel: cancelChooser, onFinish: finishChooser)
            Spacer(minLength: Theme.Space.s5)
        }
        .padding(Theme.Space.s5)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Actions
    private var stackMotion: Animation? { reduceMotion ? nil : Theme.Motion.stack }

    private func focus(_ id: Session.ID) {
        withAnimation(Theme.Motion.focus) { store.toggleFocus(id) }
    }
    private func close(_ id: Session.ID) {
        withAnimation(Theme.Motion.snappy) { store.end(id) }
    }
    private func openChooser() {
        store.browse = nil          // browse belongs to the row; close it
        withAnimation(stackMotion) { creating = true }
    }
    private func cancelChooser() {
        withAnimation(stackMotion) { creating = false }
    }
    private func finishChooser() {
        // store.create already appended the new card + took the bar; the row
        // re-expands and the new card enters at its end.
        withAnimation(stackMotion) { creating = false }
    }
}

#Preview("Stage, populated") {
    StageView()
        .environment(SessionStore(sessions: MockData.sessions))
        .environment(AuthStore())
        .preferredColorScheme(.dark)
}

#Preview("Stage, empty") {
    StageView()
        .environment(SessionStore(sessions: []))
        .environment(AuthStore())
        .preferredColorScheme(.dark)
}
