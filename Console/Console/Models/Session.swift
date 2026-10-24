import SwiftUI

// A session is the unit of the app: a what (game/movie/album) bound to a where
// (a TV, a speaker, or a group of speakers). Each card on the stage is one
// session. One device belongs to at most one session, enforced in the store.

enum SessionKind: String, CaseIterable, Hashable {
    case music, liveTV, film, apps

    var label: String {
        switch self {
        case .music:  return "MUSIC"
        case .liveTV: return "LIVE TV"
        case .film:   return "FILM"
        case .apps:   return "APPS"
        }
    }

    /// Shape encodes kind: video art is 16:10, music art is a 96pt square.
    var isVideo: Bool { self != .music }

    /// Flat placeholder gradient until real poster/album art arrives. Art is
    /// the only gradient allowed anywhere (chrome is flat).
    var artGradient: LinearGradient {
        let stops: [Color]
        switch self {
        case .liveTV: stops = [Color(hex: 0x0D4D2E), Color(hex: 0x123A22), Color(hex: 0x0A1A26)]
        case .film:   stops = [Color(hex: 0x3A2A55), Color(hex: 0x1D1730), Color(hex: 0x0D0A18)]
        case .music:  stops = [Color(hex: 0xC2871F), Color(hex: 0x8A3A14), Color(hex: 0x3A1020)]
        case .apps:   stops = [Color(hex: 0xD0452B), Color(hex: 0x7C1F3F), Color(hex: 0x28123F)]
        }
        return LinearGradient(colors: stops, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

struct Session: Identifiable, Hashable {
    let id: UUID
    var kind: SessionKind
    var title: String
    var subtitle: String
    var deviceNames: [String]
    var isLive: Bool
    var startedAt: Date

    // ---- Detail / transport state (drives the focused card body + bottom bar) ----
    var volume: Double = 0.55        // 0…1, the elastic volume bar
    var music: MusicState? = nil     // present iff kind == .music
    var subtitlesOn: Bool = false    // video kinds
    var progress: Double = 0.42      // film scrubber, 0…1
    var artSeed: Int = 0             // placeholder art variety
    var artURL: String? = nil        // real cover art once something real plays

    // ---- Real playback identity (set only when the hub confirms playback) ----
    var trackURI: String? = nil      // spotify:track:… currently on this session
    var trackID: String? = nil       // bare id (like/save)

    // ---- Search state (lives on the session, not the view: leaving the
    // stage tab unmounts the card, and the query must survive the trip) ----
    var searchQuery: String = ""
    var searchScopeRaw: String = "MUSIC"

    /// True once this session carries actual hub-confirmed playback. The
    /// elapsed timer and transport skips only exist past this point.
    var hasRealPlayback: Bool { trackURI != nil }

    /// Anything real on the room's player, including a stream started
    /// elsewhere (no Spotify identity, but pause/resume/skip still work
    /// because transport is local to the speaker).
    var hasPlaybackContext: Bool {
        trackURI != nil || isLive || playbackAccumulated > 0
    }

    // ---- Playback clock (re-synced from the hub's /spotify/player poll) ----
    // Elapsed = accumulated + time since last resume; the poll overwrites
    // accumulated with the player's real progress.
    var playbackStartedAt: Date? = nil
    var playbackAccumulated: TimeInterval = 0
    var durationSeconds: TimeInterval = 0
    /// Last local volume touch, so the poll won't stomp a fresh user drag.
    var volumeTouchedAt: Date = .distantPast
    /// Last local TV action (play/pause, app launch). Same idea: the 5s TV
    /// poll can be carrying a snapshot taken before the action landed, and
    /// applying it would visibly revert what the user just did.
    var tvTouchedAt: Date = .distantPast
    /// The app currently on the TV (hub-reported), used to remember which
    /// apps ignore an absolute seek.
    var tvAppName: String?
    /// What the app currently on the TV honours (hub-reported per poll).
    var tvCanSkip: Bool = false
    var tvCanSeek: Bool = false
    /// True once the TV reports a real now-playing session, which is what
    /// makes the scrubber and skip buttons meaningful.
    var tvHasPlayer: Bool = false

    var elapsed: TimeInterval {
        let raw = playbackAccumulated + (playbackStartedAt.map { Date.now.timeIntervalSince($0) } ?? 0)
        return durationSeconds > 0 ? min(raw, durationSeconds) : raw
    }
    /// Track position as 0…1 of the real duration (0 when unknown).
    var elapsedFraction: Double {
        durationSeconds > 0 ? min(1, elapsed / durationSeconds) : 0
    }
    var elapsedLabel: String { Self.clock(elapsed) }
    var durationLabel: String { Self.clock(durationSeconds) }

    private static func clock(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        if s >= 3600 {   // podcasts/audiobooks: h:mm:ss beats "97:12"
            return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
        }
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    init(id: UUID = UUID(), kind: SessionKind, title: String, subtitle: String,
         deviceNames: [String], isLive: Bool, startedAt: Date = .now,
         volume: Double = 0.55, music: MusicState? = nil,
         subtitlesOn: Bool = false, progress: Double = 0.42, artSeed: Int = 0) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.deviceNames = deviceNames
        self.isLive = isLive
        self.startedAt = startedAt
        self.volume = volume
        self.music = music
        self.subtitlesOn = subtitlesOn
        self.progress = progress
        self.artSeed = artSeed
    }

    /// Volume as a mono dB readout (−60…0 dB across the 0…1 rail).
    var volumeDb: String {
        let db = -60.0 * (1 - volume)
        return String(format: "%.1f", db)
    }

    /// Speaker outputs this music session is grouped across (excludes TVs).
    var speakerNames: [String] { deviceNames }

    /// The where label: a grouped-audio session shows both rooms.
    var whereLabel: String { deviceNames.joined(separator: " + ") }

    /// Confirmation rule: ending a TV session turns the TV off, so it always
    /// asks; music never confirms.
    var needsEndConfirmation: Bool { kind != .music }

    /// A new, idle session. Nothing plays until the user starts something
    /// (music: search → play; video: launch an app on the TV).
    static func fresh(kind: SessionKind, devices: [String]) -> Session {
        let content: (String, String)
        switch kind {
        case .music:  content = ("Nothing playing", "Search to start")
        case .liveTV: content = ("Live TV", "No source yet")
        case .film:   content = ("Movies & Shows", "No source yet")
        case .apps:   content = ("Apple TV", "App launcher")
        }
        return Session(kind: kind, title: content.0, subtitle: content.1,
                       deviceNames: devices, isLive: false, startedAt: .now,
                       music: kind == .music ? MusicState(groupMembers: devices) : nil,
                       artSeed: abs((devices.first ?? "").hashValue % 6))
    }
}
