import SwiftUI

// Detail-layer models for the music kind. These feed the focused music card
// body (search / queue / playlists / group) and the bottom transport bar.
// Nothing here talks to the hub; the store mutates these structs in place and
// the views reflect them.

/// A search hit. Shape drives art geometry: an artist is a circle, an album or
/// track is a square (the one place art isn't a rounded rect).
struct SearchResult: Identifiable, Hashable {
    enum Shape { case artist, album, track, playlist, show, episode, audiobook }
    let id = UUID()
    var shape: Shape
    var title: String
    var subtitle: String
    var artSeed: Int          // varies the flat placeholder gradient (mock art)
    var imageURL: String? = nil   // real cover art from the hub, when present
    var uri: String? = nil        // spotify:track:…, used for playback
    var spotifyID: String? = nil  // bare id; browse-card target for artist/album

    var isCircular: Bool { shape == .artist }

    /// Map a hub search hit into the app's result model.
    init(hub: Hub.SearchHit) {
        switch hub.kind {
        case "album":     shape = .album
        case "track":     shape = .track
        case "playlist":  shape = .playlist
        case "show":      shape = .show
        case "episode":   shape = .episode
        case "audiobook": shape = .audiobook
        default:          shape = .artist
        }
        title = hub.title
        subtitle = hub.subtitle
        artSeed = abs(hub.id.hashValue)
        imageURL = hub.image
        uri = hub.uri
        spotifyID = hub.id
    }

    init(shape: Shape, title: String, subtitle: String, artSeed: Int,
         imageURL: String? = nil, uri: String? = nil) {
        self.shape = shape
        self.title = title
        self.subtitle = subtitle
        self.artSeed = artSeed
        self.imageURL = imageURL
        self.uri = uri
    }
}

/// A row in "Up next": an upcoming entry in the room's real queue.
/// Reorderable (drag) and removable (swipe); position is the absolute Sonos
/// queue index the hub accepts for remove/reorder.
struct QueueItem: Identifiable, Hashable {
    let id = UUID()
    var title: String
    var artist: String
    var uri: String? = nil    // spotify:track:… when the entry carries identity
    var position: Int = 0
}

/// One of the user's real Spotify playlists, target of "+ Playlist" and
/// playable from the card's Playlists section.
struct Playlist: Identifiable, Hashable {
    let id: String            // Spotify playlist id
    var name: String
    var count: Int?           // Spotify occasionally omits totals
    var uri: String? = nil
    var image: String? = nil
    var isNew: Bool = false
}

/// Per-session music state. Lives on the Session; the store mutates it. Search
/// results and playlists are house-global; only the queue, group routing, and
/// the standing toggles are per session.
struct MusicState: Hashable {
    var liked = false
    var shuffle = false
    var repeatOn = false
    /// Speaker names currently carrying this session's audio (the live group).
    var groupMembers: [String] = []
    var queue: [QueueItem] = []
    /// Absolute queue position of the current track (nil = none), shown as the dot.
    var queuePosition: Int? = nil
}

/// A flat placeholder gradient seeded by an int, so placeholder art has
/// variety without real imagery. Art is the only sanctioned gradient in the app.
enum ArtPalette {
    private static let palettes: [[Color]] = {
        let hexes: [[UInt]] = [
            [0xC2871F, 0x8A3A14, 0x3A1020],
            [0x2B6E8A, 0x1E3A55, 0x0D1428],
            [0x8A2B6E, 0x55173A, 0x1D0D18],
            [0x3A7A3A, 0x1E4530, 0x0A1A14],
            [0x7A6A2B, 0x453A17, 0x18140A],
            [0x5A3A8A, 0x2E1D55, 0x120D28],
        ]
        return hexes.map { row in row.map { Color(hex: $0) } }
    }()

    static func gradient(seed: Int) -> LinearGradient {
        let stops = palettes[((seed % palettes.count) + palettes.count) % palettes.count]
        return LinearGradient(colors: stops, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}
