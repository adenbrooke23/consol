import Foundation

// Fixtures for SwiftUI previews and DEBUG UITEST_* hooks only. Nothing here is
// reachable in a normal launch: the stage starts empty, search results and
// playlists come from the hub, and new sessions are born idle (Session.fresh).
enum MockData {
    static let family: [Profile] = [
        Profile(name: "Alex", pin: "1111"),
        Profile(name: "Sam", pin: "2222"),
    ]

    // Fixtures started "a while ago" so closing them doesn't hit the <10-min
    // TV confirm prompt (freshly created sessions will).
    static let sessions: [Session] = [
        Session(kind: .liveTV, title: "Broncos @ Chiefs", subtitle: "NBC · Q4 02:11",
                deviceNames: ["Bedroom TV"], isLive: true, startedAt: .now.addingTimeInterval(-1800),
                artSeed: 3),
        Session(kind: .film, title: "Dune: Part Two", subtitle: "1:12 remaining",
                deviceNames: ["Living TV"], isLive: true, startedAt: .now.addingTimeInterval(-1800),
                progress: 0.38, artSeed: 5),
        {
            var s = Session(kind: .music, title: "In a Silent Way", subtitle: "Miles Davis",
                            deviceNames: ["Office"], isLive: true, startedAt: .now.addingTimeInterval(-1800),
                            volume: 0.62, music: musicState(group: ["Office"]), artSeed: 0)
            s.playbackStartedAt = .now.addingTimeInterval(-83)   // 1:23 into the track
            s.trackURI = "spotify:track:preview-fixture"         // marks "real" playback for previews
            return s
        }(),
    ]

    /// A larger fixture so the chooser collapse-stack can be exercised at 6 cards.
    static let sixSessions: [Session] = sessions + [
        Session(kind: .music, title: "Blue", subtitle: "Joni Mitchell",
                deviceNames: ["Kitchen"], isLive: true, startedAt: .now.addingTimeInterval(-900),
                volume: 0.5, music: musicState(group: ["Kitchen"]), artSeed: 2),
        Session(kind: .music, title: "Kind of Blue", subtitle: "Miles Davis",
                deviceNames: ["Dining"], isLive: true, startedAt: .now.addingTimeInterval(-600),
                volume: 0.44, music: musicState(group: ["Dining"]), artSeed: 1),
        Session(kind: .apps, title: "Apple TV", subtitle: "App launcher",
                deviceNames: ["Patio TV"], isLive: false, startedAt: .now.addingTimeInterval(-300),
                artSeed: 4),
    ]

    static let empty: [Session] = []

    /// Slice a fixture to an exact card count (for verifying the chooser
    /// collapse-stack at 1 / 2 / 4 / 6 sessions).
    static func fixture(count: Int) -> [Session] {
        Array(sixSessions.prefix(max(0, count)))
    }

    // MARK: Music detail fixtures ------------------------------------------------

    static func musicState(group: [String]) -> MusicState {
        MusicState(liked: false, shuffle: false, repeatOn: false,
                   groupMembers: group, queue: queue)
    }

    static let queue: [QueueItem] = [
        QueueItem(title: "Shhh / Peaceful", artist: "Miles Davis"),
        QueueItem(title: "It's About That Time", artist: "Miles Davis"),
        QueueItem(title: "Spanish Key", artist: "Miles Davis"),
        QueueItem(title: "Great Expectations", artist: "Miles Davis"),
        QueueItem(title: "Bitches Brew", artist: "Miles Davis"),
    ]

    // MARK: Video detail fixtures ------------------------------------------------

    static let channels: [String] = [
        "NBC", "ESPN", "TNT", "ABC", "FOX", "CBS", "NFL Network", "TBS",
    ]
    static let episodes: [(String, String)] = [
        ("Chapter One", "58 min"),
        ("Chapter Two", "62 min"),
        ("Chapter Three", "55 min"),
        ("Chapter Four", "60 min"),
    ]
}
