import Observation
import Foundation
import SwiftUI

// Owns the stage: the list of running sessions, which one is expanded (focused),
// and which one drives the bottom bar. App state is the card row.
//
// Two selection concepts, deliberately distinct:
//  • focusedID: the expanded card (grows 2.4×, shows in-body detail controls).
//  • barID: the session the bottom transport bar reflects. It follows the
//    last card you touched and persists after you collapse that card, so the
//    bar keeps full quick controls for it even when nothing is expanded. Only
//    ending that session (or focusing another) moves the bar.
//
// Music playback goes through the hub, which drives the room's Sonos speaker
// locally (ShareLink + SoCo transport; Spotify's Web API refuses to control
// Sonos devices). Likes and playlists use the Web API. A per-room player poll
// keeps the clock and live state accurate, and hub refusals are shown to the
// user rather than hidden.

/// What the companion browse card is showing: an artist or an album,
/// identified by its Spotify id. Opened from search results in the focused
/// music card; anything played inside it lands on that session.
struct BrowseTarget: Hashable {
    enum Kind { case artist, album, playlists, recents, show, library, search }
    var kind: Kind
    var spotifyID: String = ""   // for .search this carries the query
    var title: String = ""
    var image: String? = nil
    var scope: String = "music"  // .search only: music | podcasts | books
}

/// A transient stage-level confirmation or error, rendered as the single
/// toast capsule above the transport bar (lemon = confirm, alert = error).
struct Notice: Equatable {
    var text: String
    var isError = false
}

@Observable
@MainActor
final class SessionStore {
    var sessions: [Session]
    var focusedID: Session.ID?
    var barID: Session.ID?

    /// Companion browse card next to the focused music card (nil = closed).
    var browse: BrowseTarget?

    /// Companion remote card next to the focused video card (nil = closed).
    var remoteFor: Session.ID?

    /// A card asked to end but needs the stage-level confirm (TV sessions:
    /// ending turns the TV off). Answered by the bottom-center capsule.
    var pendingEnd: Session.ID?

    /// Full-screen now-playing takeover (nil = normal stage).
    var fullscreen: Session.ID?

    /// One transient toast for the whole stage (StageView renders + expires it).
    var notice: Notice?

    /// Hub reachability, measured by the root poll (health ping each tick).
    /// Drives the StatusStrip dot and the Profile page's HUB/NETWORK cards.
    var hubOnline = true
    var hubLatencyMs: Int?

    /// True while a start/restart/stop is running from the Profile page.
    /// The poll must not overwrite the operation's verdict with a stale
    /// in-flight ping from before the state changed.
    var hubAdminInFlight = false

    /// Physical outputs, loaded live from the hub: Sonos rooms as speakers,
    /// plus paired, room-mapped Apple TVs.
    var outputs: [Output] = []

    /// The user's real Spotify playlists (hub-loaded; picker lists these,
    /// and the card's PLAYLISTS section plays them).
    var playlists: [Playlist] = []

    /// What the house played recently (hub-tracked; discovery rows).
    var recents: [SearchResult] = []

    /// DEBUG-only: make the Stage open the chooser on appear (screenshot hook).
    var debugAutoOpenChooser = false

    /// Off for mock-fixture test launches so they never pollute real state.
    var persistenceEnabled = true

    init(sessions: [Session] = []) { self.sessions = sessions }

    // MARK: Session persistence (cards survive relaunch)
    // Only the durable identity is saved (kind + rooms); the per-room poll
    // restores now-playing state within seconds of launch.
    private struct PersistedSession: Codable {
        let kind: String
        let devices: [String]
    }
    private static let persistKey = "console.sessions.v1"

    func persistSessions() {
        guard persistenceEnabled else { return }
        let payload = sessions.map {
            PersistedSession(kind: $0.kind.rawValue, devices: $0.deviceNames)
        }
        if let data = try? JSONEncoder().encode(payload) {
            UserDefaults.standard.set(data, forKey: Self.persistKey)
        }
    }

    func restoreSessions() {
        guard persistenceEnabled, sessions.isEmpty,
              let data = UserDefaults.standard.data(forKey: Self.persistKey),
              let payload = try? JSONDecoder().decode([PersistedSession].self, from: data)
        else { return }
        for item in payload {
            guard let kind = SessionKind(rawValue: item.kind),
                  !item.devices.isEmpty else { continue }
            sessions.append(Session.fresh(kind: kind, devices: item.devices))
        }
        barID = sessions.first?.id
    }

    var isEmpty: Bool { sessions.isEmpty }
    var liveCount: Int { sessions.filter(\.isLive).count }

    /// One tap: expand + take the bar. Tap again: collapse (keep the bar).
    /// Any focus change closes the companion browse card; it belongs to the
    /// card it was opened from.
    func toggleFocus(_ id: Session.ID) {
        barID = id
        focusedID = (focusedID == id) ? nil : id
        browse = nil
        remoteFor = nil
        // An unanswered confirm sits in front of the notice capsule, so
        // leaving it stranded silently swallows every later toast.
        pendingEnd = nil
    }

    func isFocused(_ id: Session.ID) -> Bool { focusedID == id }

    // MARK: Bottom-bar context
    var barSession: Session? { barID.flatMap { id in sessions.first { $0.id == id } } }
    /// The bar collapses to art+title while its session is the expanded one
    /// (the card body already carries the controls).
    var barCollapsed: Bool { barID != nil && barID == focusedID }

    func session(_ id: Session.ID) -> Session? { sessions.first { $0.id == id } }

    /// A binding to a live session by id (so detail views can mutate in place).
    func binding(_ id: Session.ID) -> Binding<Session> {
        Binding(
            get: { self.sessions.first { $0.id == id } ?? Session(kind: .music, title: "", subtitle: "", deviceNames: [], isLive: false) },
            set: { newValue in
                if let i = self.sessions.firstIndex(where: { $0.id == id }) {
                    self.sessions[i] = newValue
                }
            }
        )
    }

    private func mutate(_ id: Session.ID, _ change: (inout Session) -> Void) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        change(&sessions[i])
    }

    // MARK: Notices
    func flash(_ text: String, isError: Bool = false) {
        withAnimation(Theme.Motion.snappy) { notice = Notice(text: text, isError: isError) }
    }

    private func notify(_ error: Swift.Error) {
        // Roaming blips are not errors: the speaker streams on its own, so a
        // transient control failure while walking between access points must
        // not paint a red capsule over healthy playback. The next poll repaints
        // the real state.
        if error is CancellationError { return }
        if let url = error as? URLError,
           [.cancelled, .timedOut, .networkConnectionLost,
            .notConnectedToInternet].contains(url.code) { return }
        if let hub = error as? Hub.Error {
            flash(hub.detail.uppercased(), isError: true)
        } else {
            flash("HUB UNREACHABLE", isError: true)
        }
    }

    // MARK: Hub-backed house state
    /// Load real outputs (Sonos rooms) and Spotify playlists. Safe to re-run;
    /// failures leave the previous values in place.
    func loadHouse() async {
        if let rooms = try? await Hub.rooms() {
            let speakers = rooms.map { Output($0.name, .speaker) }
            outputs = speakers + outputs.filter { $0.kind == .tv }
        }
        if let items = try? await Hub.playlists() {
            playlists = items.map {
                Playlist(id: $0.id, name: $0.name, count: $0.count,
                         uri: $0.uri, image: $0.image)
            }
        }
        await refreshRecents()
        // TVs load last: the hub answers /tv/devices with a ~5s LAN scan,
        // and speakers/playlists shouldn't wait behind it. Only paired,
        // room-mapped TVs become outputs; the chooser names them by room.
        if let tvs = try? await Hub.tvDevices(), !tvs.isEmpty {
            let mapped = tvs.filter { $0.paired && !$0.isProtected }
                .compactMap(\.room)
                .map { Output($0, .tv) }
            outputs = outputs.filter { $0.kind == .speaker } + mapped
        }
    }

    func refreshRecents() async {
        if let items = try? await Hub.recents() {
            recents = items.map(SearchResult.init(hub:))
        }
    }

    // MARK: Playback (music sessions ↔ hub ↔ Sonos)

    /// Fold a hub player snapshot into a session: live flag, clock, shuffle /
    /// repeat, and track identity. The hub is authoritative.
    private func apply(_ state: Hub.PlayerState, to id: Session.ID) {
        // Track changed (skip, album advancing) → the upcoming queue moved too.
        if let track = state.track, track.uri != session(id)?.trackURI {
            Task { await refreshQueue(id) }
        }
        mutate(id) {
            $0.isLive = state.active && state.isPlaying
            if let track = state.track {
                $0.title = track.title
                $0.subtitle = track.subtitle
                $0.artURL = track.image ?? $0.artURL
                // A stream without Spotify identity (started elsewhere) still
                // shows as playing; like and queue just have nothing to act on.
                $0.trackURI = track.uri
                $0.trackID = track.id
            }
            $0.playbackAccumulated = Double(state.progressMs ?? 0) / 1000
            $0.durationSeconds = Double(state.durationMs ?? 0) / 1000
            $0.playbackStartedAt = $0.isLive ? .now : nil
            if let shuffle = state.shuffle { $0.music?.shuffle = shuffle }
            if let rep = state.repeat { $0.music?.repeatOn = rep != "off" }
            // Group membership comes from the speakers, so a leftover or
            // external group still lights its chips.
            if let group = state.group, !group.isEmpty,
               Set(group) != Set($0.music?.groupMembers ?? []) {
                $0.music?.groupMembers = group
            }
            // Speaker volume is authoritative, unless the user is mid-drag.
            if let vp = state.device?.volumePercent,
               Date.now.timeIntervalSince($0.volumeTouchedAt) > 3 {
                $0.volume = Double(vp) / 100
            }
        }
    }

    private func freezePlayback(_ id: Session.ID) {
        mutate(id) {
            if let started = $0.playbackStartedAt {
                $0.playbackAccumulated += Date.now.timeIntervalSince(started)
            }
            $0.playbackStartedAt = nil
            $0.isLive = false
        }
    }

    /// Consecutive failed polls per session; a card only freezes after a few
    /// straight misses so one dropped packet can't fake a paused speaker.
    private var pollMisses: [Session.ID: Int] = [:]

    /// Poll tick: every music session asks its own room's speaker for its
    /// state (the hub reads the player locally via SoCo, not a shared
    /// account player). Rooms are polled concurrently so one unreachable
    /// room can't stall the others behind its timeout.
    func syncPlayer() async {
        // The TV poll runs alongside the music poll, never in front of it: a
        // TV that stops answering costs a full timeout plus retry, and
        // awaiting that first would push the DEBUG heartbeat past the hub's
        // 20s dead-man switch, so an unplugged TV would silence the speakers.
        async let tv: Void = syncTV()
        await syncMusic()
        await tv
    }

    private func syncMusic() async {
        let targets: [(Session.ID, String)] = sessions
            .filter { $0.kind == .music }
            .compactMap { s in s.deviceNames.first.map { (s.id, $0) } }
        guard !targets.isEmpty else { return }
        let results = await withTaskGroup(
            of: (Session.ID, Hub.PlayerState?).self
        ) { group in
            for (id, room) in targets {
                group.addTask { (id, try? await Hub.playerState(room: room)) }
            }
            var out: [(Session.ID, Hub.PlayerState?)] = []
            for await pair in group { out.append(pair) }
            return out
        }
        for (id, state) in results {
            if let state {
                pollMisses[id] = 0
                apply(state, to: id)
            } else {
                let misses = (pollMisses[id] ?? 0) + 1
                pollMisses[id] = misses
                if misses >= 3, let s = session(id),
                   s.isLive || s.playbackStartedAt != nil {
                    freezePlayback(id)   // room genuinely unreachable: stop the clock
                }
            }
        }
    }

    /// Play/pause. Music pauses or resumes this session's room through the
    /// hub; video kinds send play_pause to the room's TV.
    func togglePlay(_ id: Session.ID) {
        guard let s = session(id) else { return }
        guard s.kind == .music else {
            // Video: drive the TV. tvTouchedAt holds the optimistic state
            // until the poll catches up.
            guard let room = s.deviceNames.first else { return }
            mutate(id) { $0.isLive.toggle(); $0.tvTouchedAt = .now }
            Task {
                do { try await Hub.tvKey(room, "play_pause") }
                catch { notify(error) }
            }
            return
        }
        guard s.hasPlaybackContext, let room = s.deviceNames.first else {
            flash("NOTHING PLAYING. SEARCH TO START", isError: true)
            return
        }
        Task {
            do {
                let state = s.isLive
                    ? try await Hub.pause(room: room)
                    : try await Hub.play(room: room)
                apply(state, to: id)
            } catch { notify(error) }
        }
    }

    func nextTrack(_ id: Session.ID) { skip(id) { try await Hub.next(room: $0) } }
    func previousTrack(_ id: Session.ID) { skip(id) { try await Hub.previous(room: $0) } }

    private func skip(_ id: Session.ID,
                      _ call: @escaping (String) async throws -> Hub.PlayerState) {
        guard let s = session(id), s.hasPlaybackContext, let room = s.deviceNames.first else {
            flash("NOTHING PLAYING. SEARCH TO START", isError: true)
            return
        }
        Task {
            do { apply(try await call(room), to: id) }
            catch { notify(error) }
        }
    }

    private var volumeSendTask: Task<Void, Never>?
    private var seekSendTask: Task<Void, Never>?

    /// Volume: instant locally, debounced to the room's speaker (SoCo).
    func setVolume(_ id: Session.ID, _ v: Double) {
        let clamped = min(1, max(0, v))
        mutate(id) { $0.volume = clamped; $0.volumeTouchedAt = .now }
        guard let s = session(id), s.kind == .music, let room = s.deviceNames.first else { return }
        volumeSendTask?.cancel()
        volumeSendTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            do { try await Hub.setPlayerVolume(Int(clamped * 100), room: room) }
            catch { notify(error) }
        }
    }

    func setProgress(_ id: Session.ID, _ v: Double) { mutate(id) { $0.progress = min(1, max(0, v)) } }

    /// Scrub the current track: instant locally, debounced seek to the speaker.
    func seek(_ id: Session.ID, to fraction: Double) {
        guard let s = session(id), s.kind == .music, s.durationSeconds > 0,
              let room = s.deviceNames.first else { return }
        let target = min(1, max(0, fraction)) * s.durationSeconds
        mutate(id) {
            $0.playbackAccumulated = target
            $0.playbackStartedAt = $0.isLive ? .now : nil
        }
        seekSendTask?.cancel()
        seekSendTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            do { apply(try await Hub.seek(Int(target * 1000), room: room), to: id) }
            catch { notify(error) }
        }
    }

    func toggleShuffle(_ id: Session.ID) {
        guard let s = session(id), s.hasPlaybackContext, let room = s.deviceNames.first else {
            flash("NOTHING PLAYING. SEARCH TO START", isError: true)
            return
        }
        let on = !(s.music?.shuffle ?? false)
        Task {
            do { apply(try await Hub.setShuffle(on, room: room), to: id) }
            catch { notify(error) }
        }
    }

    func toggleRepeat(_ id: Session.ID) {
        guard let s = session(id), s.hasPlaybackContext, let room = s.deviceNames.first else {
            flash("NOTHING PLAYING. SEARCH TO START", isError: true)
            return
        }
        let on = !(s.music?.repeatOn ?? false)
        Task {
            do { apply(try await Hub.setRepeat(on, room: room), to: id) }
            catch { notify(error) }
        }
    }

    func toggleSubtitles(_ id: Session.ID) { mutate(id) { $0.subtitlesOn.toggle() } }

    // MARK: The room's queue (Up Next reflects the speaker)

    /// Re-read the room's upcoming queue into the session (rest of the
    /// playing album, user-queued extras: whatever the speaker holds).
    func refreshQueue(_ id: Session.ID) async {
        guard let s = session(id), s.kind == .music,
              let room = s.deviceNames.first else { return }
        guard let result = try? await Hub.queue(room: room) else { return }
        mutate(id) {
            $0.music?.queue = result.items.map {
                QueueItem(title: $0.title, artist: $0.subtitle,
                          uri: $0.uri, position: $0.position)
            }
            // hub position is 1-based; 0 = nothing current
            $0.music?.queuePosition = result.playingPosition > 0
                ? result.playingPosition - 1 : nil
        }
    }

    /// Skip around: jump straight to a queue entry.
    func playQueueEntry(_ id: Session.ID, _ item: QueueItem) {
        guard let s = session(id), let room = s.deviceNames.first else { return }
        Task {
            do {
                let state = try await Hub.playQueueEntry(room: room, position: item.position)
                apply(state, to: id)
                await refreshQueue(id)
            } catch { notify(error) }
        }
    }

    /// Reorder the real queue (single-row drag, like the List gesture gives us).
    func moveQueue(_ id: Session.ID, from source: IndexSet, to dest: Int) {
        guard let s = session(id), let room = s.deviceNames.first,
              let srcOffset = source.first, source.count == 1,
              let queue = s.music?.queue, queue.indices.contains(srcOffset)
        else { return }
        let fromPos = queue[srcOffset].position
        // List's toOffset is the insertion slot after removal-space handling;
        // map it to the absolute position of the row it lands before.
        let beforePos = dest >= queue.count
            ? (queue.last.map { $0.position + 1 } ?? fromPos)
            : queue[dest].position
        mutate(id) { $0.music?.queue.move(fromOffsets: source, toOffset: dest) }
        Task {
            do {
                try await Hub.queueReorder(room: room, from: fromPos, insertBefore: beforePos)
                await refreshQueue(id)
            } catch { notify(error); await refreshQueue(id) }
        }
    }

    /// Remove entries from the real queue.
    func removeQueue(_ id: Session.ID, at offsets: IndexSet) {
        guard let s = session(id), let room = s.deviceNames.first,
              let queue = s.music?.queue else { return }
        let positions = offsets.compactMap { queue.indices.contains($0) ? queue[$0].position : nil }
        mutate(id) { $0.music?.queue.remove(atOffsets: offsets) }
        Task {
            do {
                try await Hub.queueRemove(room: room, positions: positions)
                await refreshQueue(id)
            } catch { notify(error); await refreshQueue(id) }
        }
    }

    /// Queue a track behind the current content (the room's real queue).
    func enqueue(_ id: Session.ID, _ result: SearchResult) {
        guard let uri = result.uri else { return }
        Task {
            do {
                try await Hub.queueAdd(uri, room: session(id)?.deviceNames.first)
                flash("QUEUED · \(result.title.uppercased())")
                await refreshQueue(id)
            } catch { notify(error) }
        }
    }

    /// Play a search result on this session's room (results play here). A
    /// track plays directly; an album/playlist plays as a context. The card
    /// only flips to live once the hub confirms.
    func playResult(_ id: Session.ID, _ result: SearchResult) {
        guard let uri = result.uri else {
            flash("NOT PLAYABLE", isError: true)
            return
        }
        let room = session(id)?.deviceNames.first
        Task {
            do {
                // Tracks and episodes queue directly; albums/playlists are contexts.
                let playsDirectly = result.shape == .track || result.shape == .episode
                let state = playsDirectly
                    ? try await Hub.play(uris: [uri], room: room)
                    : try await Hub.play(contextURI: uri, room: room)
                mutate(id) {
                    $0.title = result.title
                    $0.subtitle = result.subtitle
                    $0.artURL = result.imageURL
                    if result.shape == .track || result.shape == .episode {
                        $0.trackURI = uri
                        $0.trackID = result.spotifyID
                    }
                }
                apply(state, to: id)   // hub state (incl. real track) wins
                flash("PLAYING · \(session(id)?.whereLabel.uppercased() ?? "")")
                // Explicit: apply()'s change-detection can't see this play
                // (the mutate above already set the tapped track's identity),
                // and Up Next must repaint to the new album/playlist queue.
                await refreshQueue(id)
            } catch { notify(error) }
        }
    }

    /// Straight switch (the default room action): move this session, and
    /// its audio mid-song, to another room. Old rooms drop; grouping is a
    /// separate, deliberate mode (toggleGroupMember).
    func switchRoom(_ id: Session.ID, to room: String) {
        guard let s = session(id), s.kind == .music,
              let anchor = s.deviceNames.first else { return }
        guard s.deviceNames != [room] else { return }
        Task {
            do {
                let state = try await Hub.switchRoom(from: anchor, to: room)
                mutate(id) {
                    $0.deviceNames = [room]
                    $0.music?.groupMembers = [room]
                }
                persistSessions()
                apply(state, to: id)
                flash("MOVED TO \(room.uppercased())")
            } catch { notify(error) }
        }
    }

    /// Play a context (playlist/album) from a given track index on this
    /// session's room. The tapped track's identity paints the card until the
    /// hub's confirmed state lands.
    func playContext(_ id: Session.ID, uri: String, startIndex: Int,
                     title: String, subtitle: String, image: String?) {
        guard let room = session(id)?.deviceNames.first else { return }
        Task {
            do {
                let state = try await Hub.play(contextURI: uri, room: room,
                                               startIndex: startIndex)
                mutate(id) {
                    $0.title = title
                    $0.subtitle = subtitle
                    $0.artURL = image
                }
                apply(state, to: id)
                flash("PLAYING · \(session(id)?.whereLabel.uppercased() ?? "")")
                await refreshQueue(id)   // same reason as playResult
            } catch { notify(error) }
        }
    }

    /// Group mode: toggle a speaker in this music session's group. This is
    /// real Sonos routing: adding joins the room to the session's group
    /// (audio follows instantly), removing unjoins it. Local state commits
    /// only after the hub confirms.
    func toggleGroupMember(_ id: Session.ID, _ speaker: String) {
        guard let s = session(id), s.music != nil,
              let anchor = s.deviceNames.first else { return }
        let isMember = s.music!.groupMembers.contains(speaker)
        if isMember {
            guard s.music!.groupMembers.count > 1 else { return }  // never empty the group
        }
        Task {
            do {
                if isMember {
                    try await Hub.ungroup(speaker)
                } else {
                    try await Hub.group([anchor, speaker])
                }
                mutate(id) {
                    if isMember {
                        $0.music!.groupMembers.removeAll { $0 == speaker }
                    } else {
                        $0.music!.groupMembers.append(speaker)
                    }
                    $0.deviceNames = $0.music!.groupMembers
                }
                persistSessions()
            } catch { notify(error) }
        }
    }

    // MARK: Devices (resources)

    /// The session currently using an output, if any (device→session is 1:1).
    func owner(of output: Output) -> Session? {
        sessions.first { $0.deviceNames.contains(output.name) }
    }
    func isFree(_ output: Output) -> Bool { owner(of: output) == nil }

    // MARK: Lifecycle
    /// End a session; its devices become free. Clears focus and empties the
    /// bar to idle if this was the bar's context.
    ///
    /// Break-glass rule: a closed card goes silent. Pause the session's room
    /// (the group coordinator, so grouped rooms stop together)
    /// unconditionally: `isLive` lags right after a play starts (the speaker
    /// reports "transitioning"), so gating on it can leave music playing.
    /// Pausing an idle room is harmless. This is best-effort and quiet, since
    /// the card is already gone.
    func end(_ id: Session.ID) {
        if let s = session(id), let room = s.deviceNames.first {
            if s.kind == .music {
                Task { try? await Hub.pause(room: room) }
            } else {
                // A TV session owns its TV: ending it turns the TV off.
                Task { try? await Hub.tvPower(room, on: false) }
            }
        }
        if focusedID == id { focusedID = nil; browse = nil }
        if barID == id { barID = nil }
        if remoteFor == id { remoteFor = nil }
        if pendingEnd == id { pendingEnd = nil }
        sessions.removeAll { $0.id == id }
        persistSessions()
    }

    /// App-wide break glass: the app is terminating, so silence every room
    /// this instance controls. Deliberately near-synchronous: async Tasks die
    /// with the process, so requests are fired and given a short window to
    /// land.
    nonisolated func panicStopAll(rooms: [String]) {
        guard !rooms.isEmpty, Hub.baseURL.host()?.isEmpty == false else { return }
        let group = DispatchGroup()
        for room in rooms {
            var request = URLRequest(url: Hub.baseURL.appendingPathComponent("spotify/pause"))
            request.httpMethod = "POST"
            request.timeoutInterval = 2
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONEncoder().encode(["room": room])
            group.enter()
            URLSession.shared.dataTask(with: request) { _, _, _ in group.leave() }.resume()
        }
        _ = group.wait(timeout: .now() + 1.5)
    }

    /// The rooms of every music session (for the termination handler).
    var musicRooms: [String] {
        sessions.filter { $0.kind == .music }.compactMap(\.deviceNames.first)
    }

    /// Create a session on the given outputs. Any session already holding
    /// one of those outputs is taken over (ended): one device, one session.
    /// Sessions start idle; playback starts from search.
    @discardableResult
    func create(kind: SessionKind, on outputs: [Output]) -> Session {
        let names = outputs.map(\.name)
        // End displaced sessions exactly as the × button does, so a displaced
        // TV is powered off and no focus, remote or pending-confirm slot is
        // left pointing at a dead id.
        for displaced in sessions.filter({ !$0.deviceNames.filter(names.contains).isEmpty }) {
            end(displaced.id)
        }
        let session = Session.fresh(kind: kind, devices: names)
        sessions.append(session)
        barID = session.id   // the new session takes the bar
        // A multi-speaker music session is a real Sonos group from the start
        // (first room = coordinator); otherwise only the first room would
        // carry audio. Best-effort; the room chips can repair routing.
        if kind == .music, names.count > 1 {
            Task { try? await Hub.group(names) }
        }
        // A TV session starts by waking its TV (CEC brings the screen up).
        // Failures are surfaced, not swallowed: a silent no-op here leaves the
        // user staring at a dark TV wondering what the card is for.
        if kind != .music, let tvName = names.first {
            Task {
                do { try await Hub.tvPower(tvName, on: true) }
                catch { notify(error) }
            }
        }
        persistSessions()
        return session
    }

    // MARK: Apple TV (video sessions drive their room's mapped TV via the hub)

    /// The room name a video session's TV commands target (hub resolves
    /// room → Apple TV through the admin-set mapping).
    private func tvRoom(_ id: Session.ID) -> String? {
        guard let s = session(id), s.kind != .music else { return nil }
        return s.deviceNames.first
    }

    func pressTVKey(_ id: Session.ID, _ key: String) {
        guard let room = tvRoom(id) else { return }
        Task {
            do { try await Hub.tvKey(room, key) }
            catch { notify(error) }
        }
    }

    private var textSendTask: Task<Void, Never>?
    private var textFieldMissingReported = false

    /// Live-sync typed text into the TV's focused field (remote card).
    ///
    /// `text_set` replaces the whole field, so two overlapping sends settle on
    /// whichever lands last, not whichever was typed last, and since the view
    /// only resends on the next keystroke, a stale winner sticks. Keeping one
    /// send in flight at a time (same shape as the volume/seek debounce
    /// above) prevents that.
    func typeOnTV(_ id: Session.ID, _ text: String) {
        guard let room = tvRoom(id) else { return }
        textSendTask?.cancel()
        textSendTask = Task {
            guard !Task.isCancelled else { return }
            do {
                try await Hub.tvText(room, text)
                textFieldMissingReported = false
            } catch let error as Hub.Error where error.isConflict {
                // Nothing on the TV accepts text yet. Say so once; this fires
                // on every keystroke burst otherwise.
                if !textFieldMissingReported {
                    textFieldMissingReported = true
                    notify(error)
                }
            } catch {
                notify(error)
            }
        }
    }

    /// Reset the once-only "no text field" notice when the remote card opens.
    func resetTVTextNotice() { textFieldMissingReported = false }

    /// Skip by a fixed interval on the TV. Without an explicit interval the
    /// app picks its own (often 15 or 30s), so "back 10" has to say 10.
    func skipTV(_ id: Session.ID, seconds: Double) {
        guard let s = session(id), let room = tvRoom(id) else { return }
        let key = seconds < 0 ? "skip_backward" : "skip_forward"
        let before = s.elapsed
        // Move the local clock straight away; the poll confirms.
        mutate(id) {
            $0.playbackAccumulated = max(0, $0.elapsed + seconds)
            $0.playbackStartedAt = $0.isLive ? .now : nil
            $0.tvTouchedAt = .now
        }
        Task {
            do {
                try await Hub.tvKey(room, key, seconds: abs(seconds))
                // Apps decide whether to honour a skip at all (Hulu blocks it
                // during ad breaks), so confirm rather than leaving an
                // optimistic position on screen that never happened.
                try? await Task.sleep(for: .milliseconds(1500))
                await refreshTV(id)
                if let after = session(id)?.elapsed,
                   abs(after - (before + seconds)) > 8 {
                    flash("COULDN'T MOVE IT. ADS BLOCK SKIPPING", isError: true)
                }
            } catch { notify(error) }
        }
    }

    /// Pull one TV session's state right now, ignoring the post-action guard.
    func refreshTV(_ id: Session.ID) async {
        guard let room = tvRoom(id),
              let status = try? await Hub.tvStatus(room) else { return }
        mutate(id) { $0.tvTouchedAt = .distantPast }
        apply(tv: status, to: id)
    }

    private var tvSeekTask: Task<Void, Never>?

    /// Scrub the TV to a fraction of the running time. Some apps (Hulu) accept
    /// the command and ignore it, so the hub reports whether it landed and the
    /// app says so rather than leaving the thumb at a position never reached.
    func seekTV(_ id: Session.ID, to fraction: Double) {
        guard let s = session(id), let room = tvRoom(id), s.durationSeconds > 0,
              s.tvHasPlayer else { return }
        let target = Int((s.durationSeconds * min(1, max(0, fraction))).rounded())
        mutate(id) {
            $0.playbackAccumulated = TimeInterval(target)
            $0.playbackStartedAt = $0.isLive ? .now : nil
            $0.tvTouchedAt = .now
        }
        tvSeekTask?.cancel()
        tvSeekTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            do {
                let applied = try await Hub.tvSeek(room, to: target)
                if !applied {
                    // A refusal is momentary, not a capability: Hulu blocks
                    // transport during a commercial and accepts it the rest
                    // of the time, so the control is never disabled over it.
                    flash("COULDN'T MOVE IT. ADS BLOCK SCRUBBING", isError: true)
                    await refreshTV(id)      // snap the thumb back to the real position
                }
            } catch { notify(error) }
        }
    }

    /// The TV half of the poll: each video session reads its TV's status and
    /// the card reflects what's actually playing there (title, app, artwork).
    private func syncTV() async {
        let targets: [(Session.ID, String)] = sessions
            .filter { $0.kind != .music }
            .compactMap { s in s.deviceNames.first.map { (s.id, $0) } }
        guard !targets.isEmpty else { return }
        let results = await withTaskGroup(
            of: (Session.ID, String, Hub.TVStatus?).self
        ) { group in
            for (id, room) in targets {
                group.addTask { (id, room, try? await Hub.tvStatus(room)) }
            }
            var out: [(Session.ID, String, Hub.TVStatus?)] = []
            for await triple in group { out.append(triple) }
            return out
        }
        for (id, _, status) in results {
            guard let status else { continue }
            apply(tv: status, to: id)
        }
    }

    /// Fold one TV snapshot into a session. Shared by the 5s poll and the
    /// confirming refresh after a skip.
    private func apply(tv status: Hub.TVStatus, to id: Session.ID) {
        guard let room = tvRoom(id) else { return }
        mutate(id) { s in
                // A snapshot taken before the user's last action would revert
                // it on screen; let their action stand until the TV catches up.
                guard Date.now.timeIntervalSince(s.tvTouchedAt) > 3 else { return }
                s.isLive = status.isPlaying

                // Real playback clock, same shape the music path uses: the
                // poll sets the anchor, `elapsed` ticks between polls.
                s.tvHasPlayer = status.position != nil && (status.totalTime ?? 0) > 0
                s.tvAppName = status.app
                s.tvCanSkip = (status.can?.skipBackward ?? false)
                    || (status.can?.skipForward ?? false)
                s.tvCanSeek = status.can?.seek ?? false
                if s.tvHasPlayer {
                    s.durationSeconds = TimeInterval(status.totalTime ?? 0)
                    s.playbackAccumulated = TimeInterval(status.position ?? 0)
                    s.playbackStartedAt = status.isPlaying ? .now : nil
                } else {
                    s.durationSeconds = 0
                    s.playbackAccumulated = 0
                    s.playbackStartedAt = nil
                }
                if let title = status.title, !title.isEmpty {
                    // Real media on screen: the card takes its identity.
                    s.title = title
                    s.subtitle = [status.app,
                                  status.state == "paused" ? "Paused" : nil]
                        .compactMap { $0 }.joined(separator: " · ")
                    s.artURL = Hub.tvArtworkURL(room, key: title)
                } else {
                    // Idle: keep whatever the card says (launched app name),
                    // just don't show stale art or claim the TV is on.
                    s.artURL = nil
                    if status.power == "off" { s.subtitle = "TV off" }
                }
        }
    }

    /// Launch an app on the session's TV; the card takes the app's name.
    func launchTVApp(_ id: Session.ID, _ app: Hub.TVApp) {
        guard let room = tvRoom(id) else { return }
        Task {
            do {
                try await Hub.tvLaunch(room, app: app.id)
                mutate(id) {
                    $0.title = app.name
                    $0.subtitle = "On \(room)"
                    $0.tvTouchedAt = .now      // don't let the poll revert it
                }
            } catch { notify(error) }
        }
    }

    #if DEBUG
    /// Debug fixture flip (empty ⟷ 3 sessions). Wired to the Profile tab's
    /// debug control and used by previews.
    func toggleFixture() {
        sessions = isEmpty ? MockData.sessions : []
        focusedID = nil
        barID = nil
    }
    #endif
}
