import SwiftUI

// The music card's in-place detail body (Spotify via the hub). Everything
// happens inside the focused card, with no modals or sheets:
//   • Pinned header: now-playing readout, shuffle/repeat, Recents/Playlists
//     (browse-card openers). No like/add-to-playlist: Spotify rejects all
//     writes for development-mode API apps, so those affordances are absent.
//   • Search: the well + scope chips live here; results live in the
//     companion browse card beside this one, repainting as you type
//     (tapping there plays on this card / drills artists & albums)
//   • Up Next: the room's real queue (lemon dot = current, tap to jump)
//   • Speakers: room chips (tap = switch, link toggle = group mode)
// Confirmations and errors surface through the stage notice capsule.

struct MusicDetailView: View {
    @Binding var session: Session
    @Environment(SessionStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var motion: Animation? { reduceMotion ? nil : Theme.Motion.snappy }

    // Search state lives on the session so it survives tab switches (the card
    // is unmounted while Profile etc. is open); the user closes results by hand.
    private var query: Binding<String> { $session.searchQuery }
    private var scope: SearchScope { SearchScope(rawValue: session.searchScopeRaw) ?? .music }

    enum SearchScope: String, CaseIterable {
        case music = "MUSIC", podcasts = "PODCASTS", books = "BOOKS"
        var api: String {
            switch self {
            case .music: "music"; case .podcasts: "podcasts"; case .books: "books"
            }
        }
    }
    @State private var grouping = false   // room chips: switch (default) vs group
    @FocusState private var searchFocused: Bool

    private var id: Session.ID { session.id }
    private var music: MusicState { session.music ?? MusicState() }

    var body: some View {
        // The now-playing readout + control row stay pinned; only the
        // sections below them scroll.
        VStack(alignment: .leading, spacing: Theme.Space.s3) {
            pinnedHeader
            mainList
        }
        #if DEBUG
        .onAppear {
            if let q = ProcessInfo.processInfo.environment["UITEST_MUSIC_QUERY"] {
                session.searchQuery = q
            }
            switch ProcessInfo.processInfo.environment["UITEST_MUSIC_PAGE"] {
            case "toast":  store.flash("PLAYING · DEBUG")
            case "on":     session.music?.shuffle = true
                           session.music?.repeatOn = true
            default: break
            }
        }
        #endif
        // Up Next is the room's real queue; recents refresh with the card too.
        .task {
            await store.refreshQueue(id)
            await store.refreshRecents()
        }
        // Debounced live search: results live in the companion browse card
        // (same clean-visibility pattern as tapping an artist), repainting
        // beside this card as the query changes. Keyed on session state, so
        // returning from another tab reopens the results where you left off.
        .task(id: session.searchQuery + "|" + scope.rawValue) {
            let q = session.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !q.isEmpty else {
                if store.browse?.kind == .search {
                    withAnimation(motion) { store.browse = nil }
                }
                return
            }
            try? await Task.sleep(for: .milliseconds(350))
            if Task.isCancelled { return }
            withAnimation(motion) {
                store.browse = BrowseTarget(kind: .search, spotifyID: q,
                                            title: q, scope: scope.api)
            }
        }
    }

    // MARK: Pinned header (never scrolls away) --------------------------------
    private var pinnedHeader: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s2) {
            // Now-playing is a readout, not navigation; browsing happens
            // through search results and the companion browse card.
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title).typo(.cardTitle).foregroundStyle(Theme.ink).lineLimit(1)
                Text(session.subtitle)
                    .font(.custom(FontStack.ui.regular, size: 12.5))
                    .foregroundStyle(Theme.ink2).lineLimit(1)
            }

            HStack(spacing: Theme.Space.s2) {
                GlyphToggle(onName: "shuffle", isOn: music.shuffle,
                            a11y: "Shuffle") { store.toggleShuffle(id) }
                GlyphToggle(onName: "repeat", isOn: music.repeatOn,
                            a11y: "Repeat") { store.toggleRepeat(id) }
                Spacer(minLength: 0)
                // Recents/Playlists open the companion browse card, the same
                // pattern as tapping an artist result.
                browseButton(icon: "clock.arrow.circlepath", label: "Recents",
                             target: BrowseTarget(kind: .recents))
                browseButton(icon: "music.note.list", label: "Playlists",
                             target: BrowseTarget(kind: .playlists))
                browseButton(icon: "books.vertical", label: "Library",
                             target: BrowseTarget(kind: .library))
            }
            .padding(.top, 2)
        }
    }

    private func browseButton(icon: String, label: String, target: BrowseTarget) -> some View {
        Button {
            withAnimation(motion) {
                store.browse = (store.browse?.kind == target.kind) ? nil : target
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                Text(label).font(.custom(FontStack.ui.medium, size: 12))
            }
            .foregroundStyle(Theme.ink2)
            .padding(.vertical, 6).padding(.horizontal, Theme.Space.s2)
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.key).stroke(Theme.rule, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Browse \(label)")
    }

    // MARK: Scrolling sections ---------------------------------------------------
    private var mainList: some View {
        List {
            #if DEBUG
            if ProcessInfo.processInfo.environment["UITEST_MUSIC_PAGE"] == "lower" {
                queueSection
                speakerSection
            } else {
                searchSection
                queueSection
                speakerSection
            }
            #else
            searchSection
            queueSection
            speakerSection
            #endif
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.hidden)
        .environment(\.defaultMinListRowHeight, 0)
    }

    // Section labels are plain rows, not Section headers: plain-list headers
    // pin while scrolling and slide over the rows beneath, hiding song titles
    // right below the art. Same face, no pinning.
    private var searchSection: some View {
        Section {
            sectionHeader("SEARCH")
            HStack(spacing: Theme.Space.s2) {
                Image(systemName: "magnifyingglass").font(.system(size: 14)).foregroundStyle(Theme.ink3)
                TextField("Search Spotify", text: query)
                    .font(.custom(FontStack.ui.regular, size: 14))
                    .foregroundStyle(Theme.ink)
                    .textFieldStyle(.plain)
                    .submitLabel(.search)
                    .focused($searchFocused)
            }
            .padding(Theme.Space.s3)
            .background(Theme.well)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.key))
            // The bare TextField's hit area is just its thin text line, so
            // taps on the icon or padding would go nowhere. The whole well is
            // the target; re-assert focus async so it also wins over the
            // window-level dismiss tap.
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded {
                DispatchQueue.main.async { searchFocused = true }
            })
            .plainRow()

            // Scope chips: what search looks for. Same capsule face as the
            // speaker chips; selection = indigo fill (state, not signal).
            // Gesture, not Button: this row sits inside the editing text
            // field's gesture band, where Buttons lose taps.
            HStack(spacing: Theme.Space.s2) {
                ForEach(SearchScope.allCases, id: \.self) { s in
                    Text(s.rawValue)
                        .font(.custom(FontStack.mono.regular, size: 9.5))
                        .tracking(0.1 * 9.5)
                        .foregroundStyle(scope == s ? Theme.ink : Theme.ink3)
                        .padding(.vertical, 6).padding(.horizontal, Theme.Space.s3)
                        .background(scope == s ? Theme.Indigo.i500 : .clear)
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(scope == s ? .clear : Theme.rule, lineWidth: 1))
                        .contentShape(Capsule())
                        .simultaneousGesture(TapGesture().onEnded {
                            withAnimation(motion) { session.searchScopeRaw = s.rawValue }
                        })
                        .accessibilityAddTraits(scope == s ? [.isButton, .isSelected] : .isButton)
                        .accessibilityLabel("Search \(s.rawValue.lowercased())")
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
            .plainRow()

        } footer: {
            Text("RESULTS OPEN BESIDE · PLAY ON \(session.whereLabel.uppercased())")
                .font(.custom(FontStack.mono.regular, size: 9.5))
                .tracking(0.1 * 9.5)
                .foregroundStyle(Theme.ink3)
                .padding(.vertical, Theme.Space.s2)
                .plainRow()
        }
    }

    // Up Next is the room's whole queue. Lemon dot = the current track; tap a
    // row to jump straight to it. Hidden while the queue is empty.
    @ViewBuilder private var queueSection: some View {
        if !music.queue.isEmpty {
            Section {
                sectionHeader("UP NEXT")
                ForEach(music.queue) { item in
                    QueueRow(item: item,
                             playing: music.queuePosition == item.position,
                             onPlay: { store.playQueueEntry(id, item) })
                        .plainRow()
                }
                .onMove { store.moveQueue(id, from: $0, to: $1) }
                .onDelete { store.removeQueue(id, at: $0) }
            }
        }
    }

    // Chip tap = straight switch (move the session there). The link toggle
    // arms group mode, so adding rooms is always a deliberate choice.
    private var speakerSection: some View {
        Section {
            sectionHeader(grouping ? "SPEAKERS · GROUP" : "SPEAKERS · SWITCH")
            HStack(spacing: Theme.Space.s2) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Space.s2) {
                        ForEach(store.outputs.filter { $0.kind == .speaker }) { output in
                            SpeakerChip(name: output.name,
                                        inGroup: music.groupMembers.contains(output.name),
                                        live: session.isLive && music.groupMembers.contains(output.name)) {
                                if grouping {
                                    store.toggleGroupMember(id, output.name)
                                } else {
                                    store.switchRoom(id, to: output.name)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                Spacer(minLength: 0)
                GlyphToggle(onName: "link", isOn: grouping,
                            a11y: "Group mode") { grouping.toggle() }
            }
            .plainRow()
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text).typo(.label).foregroundStyle(Theme.ink3)
            .padding(.top, Theme.Space.s3).padding(.bottom, Theme.Space.s1)
            .plainRow()
    }
}

// MARK: Rows & chips ------------------------------------------------------------

// Rows use tap gestures, not Buttons: while the search TextField has keyboard
// focus, UIKit consumes a Button's first tap to resign focus (the first tap is
// lost, the second works). Gestures fire on the first tap regardless, so keep
// these as gestures.

private struct QueueRow: View {
    let item: QueueItem
    let playing: Bool
    var onPlay: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.s3) {
            HStack(spacing: Theme.Space.s3) {
                Image(systemName: "line.3.horizontal").font(.system(size: 13)).foregroundStyle(Theme.ink3)
                // Fixed slot so titles stay aligned; lemon dot = current track.
                Circle()
                    .fill(playing ? Theme.signal : .clear)
                    .frame(width: 5, height: 5)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title).font(.custom(FontStack.ui.medium, size: 13.5)).foregroundStyle(Theme.ink).lineLimit(1)
                    Text(item.artist).font(.custom(FontStack.ui.regular, size: 11.5)).foregroundStyle(Theme.ink2).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded(onPlay))   // jump to this track
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("\(item.title)\(playing ? ", playing" : "")")

        }
        .padding(.vertical, Theme.Space.s1)
    }
}

// Shared List-row reset so rows sit flush on the black card body.
private extension View {
    func plainRow() -> some View {
        self
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
    }
}
