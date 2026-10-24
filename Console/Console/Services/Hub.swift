import Foundation

// Thin client for the hub. The app talks only to the hub, never to Spotify
// directly. In the simulator the hub is reachable on the host's loopback; on a
// device it is the hub Mac's LAN address.

enum Hub {
    // The hub's host is discovered over Bonjour (the keeper advertises
    // _consol-hub._tcp, see HubDiscovery) and remembered across launches.
    // The manual address on the Profile screen writes the same slot. A
    // device build has no default: until one of those supplies a host,
    // requests fail fast and the app shows the hub as offline.
    #if targetEnvironment(simulator)
    static let defaultHost = "127.0.0.1"   // the simulator shares the Mac's loopback
    #else
    static let defaultHost = ""
    #endif

    private static let hostKey = "console.hubhost"

    /// Where the hub lives right now. Persisted so a relaunch reaches the
    /// right Mac immediately; empty or default writes clear the override.
    static var host: String {
        get { UserDefaults.standard.string(forKey: hostKey) ?? defaultHost }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed == defaultHost {
                UserDefaults.standard.removeObject(forKey: hostKey)
            } else {
                UserDefaults.standard.set(trimmed, forKey: hostKey)
            }
        }
    }

    static var baseURL: URL { url(port: 8000) }

    /// An unset or malformed host yields a URL with an empty host, which
    /// `runOnce` refuses before it reaches the network.
    private static func url(port: Int) -> URL {
        URL(string: "http://\(host):\(port)") ?? URL(string: "http://:\(port)")!
    }

    // Roaming-tolerant transport. URLSession.shared keeps dead sockets pooled
    // across a Wi-Fi access point roam, stalling every request for the full
    // timeout. A dedicated session with a short request timeout fails a stale
    // socket fast, and the resource ceiling bounds any single request.
    // waitsForConnectivity stays off: it makes requests to a dead hub hang
    // for the full ceiling, delaying offline detection by minutes. Roam
    // recovery is the GET retry below plus the poll's three-miss tolerance.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 6
        config.timeoutIntervalForResource = 15
        return URLSession(configuration: config)
    }()

    struct SearchHit: Decodable, Identifiable {
        let kind: String          // "artist" | "album" | "track"
        let id: String
        let uri: String
        let title: String
        let subtitle: String
        let image: String?
    }
    private struct SearchResponse: Decodable { let results: [SearchHit] }

    /// Artist browse page: top tracks + albums (hub-normalized).
    struct ArtistPage: Decodable {
        let id: String
        let name: String
        let image: String?
        let topTracks: [SearchHit]
        let albums: [SearchHit]
    }

    /// Album browse page: header + track list (hub-normalized).
    struct AlbumPage: Decodable {
        let id: String
        let title: String
        let artist: String
        let year: String
        let image: String?
        let tracks: [SearchHit]
    }

    /// Hub-reported error (the `detail` string from a 4xx/5xx JSON body).
    /// 409s carry actionable messages ("no spotify device for room …").
    struct Error: LocalizedError {
        let status: Int
        let detail: String
        var errorDescription: String? { detail }
        /// Caller-resolvable (nothing to play on / not connected) vs upstream.
        var isConflict: Bool { status == 409 }
    }

    /// Normalized playback snapshot (per-room from the speaker, or the
    /// account's active player when queried without a room). A stream the
    /// speaker started elsewhere has no Spotify identity, so id/uri are nil.
    struct PlayerState: Decodable {
        let active: Bool
        let isPlaying: Bool
        var progressMs: Int?
        var durationMs: Int?
        var shuffle: Bool?
        var `repeat`: String?
        var device: Device?
        var group: [String]?   // speaker-side group membership (visible rooms)
        var track: Track?
        struct Device: Decodable {
            let id: String?
            let name: String?
            let volumePercent: Int?
        }
        struct Track: Decodable {
            let id: String?
            let uri: String?
            let title: String
            let subtitle: String
            let image: String?
        }
    }

    struct PlaylistItem: Decodable, Identifiable {
        let id: String
        let name: String
        let count: Int?      // Spotify occasionally omits totals
        let uri: String
        var image: String?
    }

    /// What the house played recently (hub-tracked, newest first).
    static func recents(limit: Int = 12) async throws -> [SearchHit] {
        struct Reply: Decodable { let items: [SearchHit] }
        let reply: Reply = try await get("spotify/recents", query: [
            URLQueryItem(name: "limit", value: String(limit))
        ])
        return reply.items
    }

    static func search(_ query: String, scope: String = "music") async throws -> [SearchHit] {
        let response: SearchResponse = try await get(
            "spotify/search",
            query: [URLQueryItem(name: "q", value: query),
                    URLQueryItem(name: "limit", value: "8"),
                    URLQueryItem(name: "scope", value: scope)]
        )
        return response.results
    }

    /// Show/audiobook page (episodes = chapters for books).
    struct ShowPage: Decodable {
        let id: String
        let name: String
        let publisher: String
        let image: String?
        let episodes: [SearchHit]
    }

    static func show(_ id: String) async throws -> ShowPage {
        try await get("spotify/shows/\(id)")
    }

    /// Saved shows + audiobooks.
    struct LibraryPage: Decodable {
        let shows: [SearchHit]
        let audiobooks: [SearchHit]
    }

    static func library() async throws -> LibraryPage {
        try await get("spotify/library")
    }

    static func artist(_ id: String) async throws -> ArtistPage {
        try await get("spotify/artists/\(id)")
    }

    static func album(_ id: String) async throws -> AlbumPage {
        try await get("spotify/albums/\(id)")
    }

    // MARK: Playback (speakers stream on their own; audio never passes through the app)

    /// A room's playback state, read from the speaker itself over the LAN.
    /// DEBUG builds mark the poll as a heartbeat: if it stops (app killed,
    /// simulator quit), the hub's dead-man switch pauses the room.
    static func playerState(room: String) async throws -> PlayerState {
        var query = [URLQueryItem(name: "room", value: room)]
        #if DEBUG
        query.append(URLQueryItem(name: "watch", value: "1"))
        #endif
        return try await get("spotify/player", query: query)
    }

    /// Start tracks / a context on a room. startIndex picks where in the
    /// context (album/playlist) to begin. Only `room` = resume there.
    @discardableResult
    static func play(uris: [String]? = nil, contextURI: String? = nil,
                     room: String? = nil, startIndex: Int = 0) async throws -> PlayerState {
        struct Body: Encodable {
            let uris: [String]?; let contextUri: String?
            let room: String?; let startIndex: Int
        }
        return try await send("POST", "spotify/play",
                              body: Body(uris: uris, contextUri: contextURI,
                                         room: room, startIndex: startIndex))
    }

    /// A playlist's tracks (flat, for the browse card's playlist page).
    static func playlistTracks(_ id: String, limit: Int = 50) async throws -> [SearchHit] {
        struct Reply: Decodable { let items: [SearchHit] }
        let reply: Reply = try await get("spotify/playlists/\(id)/tracks", query: [
            URLQueryItem(name: "limit", value: String(limit))
        ])
        return reply.items
    }

    // Every control call names its room, which the hub resolves to a LAN
    // speaker. Other devices on the same Spotify account are never targeted.
    private struct RoomBody: Encodable { let room: String }

    @discardableResult
    static func pause(room: String) async throws -> PlayerState {
        try await send("POST", "spotify/pause", body: RoomBody(room: room))
    }

    @discardableResult
    static func next(room: String) async throws -> PlayerState {
        try await send("POST", "spotify/next", body: RoomBody(room: room))
    }

    @discardableResult
    static func previous(room: String) async throws -> PlayerState {
        try await send("POST", "spotify/previous", body: RoomBody(room: room))
    }

    @discardableResult
    static func setShuffle(_ on: Bool, room: String) async throws -> PlayerState {
        struct Body: Encodable { let state: Bool; let room: String }
        return try await send("PUT", "spotify/shuffle", body: Body(state: on, room: room))
    }

    @discardableResult
    static func setRepeat(_ on: Bool, room: String) async throws -> PlayerState {
        struct Body: Encodable { let state: String; let room: String }
        return try await send("PUT", "spotify/repeat",
                              body: Body(state: on ? "context" : "off", room: room))
    }

    @discardableResult
    static func setPlayerVolume(_ percent: Int, room: String) async throws -> PlayerState {
        struct Body: Encodable { let percent: Int; let room: String }
        return try await send("PUT", "spotify/volume", body: Body(percent: percent, room: room))
    }

    /// Scrub the current track (milliseconds).
    @discardableResult
    static func seek(_ positionMs: Int, room: String) async throws -> PlayerState {
        struct Body: Encodable { let room: String; let positionMs: Int }
        return try await send("POST", "spotify/seek", body: Body(room: room, positionMs: positionMs))
    }

    // MARK: Room routing (Sonos grouping)

    struct GroupReply: Decodable { let coordinator: String; let members: [String] }

    /// Join rooms into one group; first room is the anchor/coordinator.
    @discardableResult
    static func group(_ rooms: [String]) async throws -> GroupReply {
        struct Body: Encodable { let rooms: [String] }
        return try await send("POST", "spotify/group", body: Body(rooms: rooms))
    }

    static func ungroup(_ room: String) async throws {
        struct Reply: Decodable { let room: String }
        let _: Reply = try await send("POST", "spotify/ungroup", body: RoomBody(room: room))
    }

    /// Straight switch: move playback to another room (audio carries over).
    @discardableResult
    static func switchRoom(from: String, to: String) async throws -> PlayerState {
        struct Body: Encodable { let fromRoom: String; let toRoom: String }
        return try await send("POST", "spotify/switch", body: Body(fromRoom: from, toRoom: to))
    }

    static func queueAdd(_ uri: String, room: String? = nil) async throws {
        struct Body: Encodable { let uri: String; let room: String? }
        struct Reply: Decodable { let queued: String }
        let _: Reply = try await send("POST", "spotify/queue", body: Body(uri: uri, room: room))
    }

    /// One upcoming entry in a room's real queue. `position` is the absolute
    /// queue index the hub accepts back for remove/reorder.
    struct QueueEntry: Decodable {
        let position: Int
        let title: String
        let subtitle: String
        let uri: String?
        let image: String?
    }

    /// The room's whole queue + the current track's 1-based position (0 = none).
    static func queue(room: String, limit: Int = 100) async throws -> (items: [QueueEntry], playingPosition: Int) {
        struct Reply: Decodable { let items: [QueueEntry]; let playingPosition: Int }
        let reply: Reply = try await get("spotify/queue", query: [
            URLQueryItem(name: "room", value: room),
            URLQueryItem(name: "limit", value: String(limit)),
        ])
        return (reply.items, reply.playingPosition)
    }

    /// Jump to a queue entry (absolute 0-based) and play it.
    @discardableResult
    static func playQueueEntry(room: String, position: Int) async throws -> PlayerState {
        struct Body: Encodable { let room: String; let position: Int }
        return try await send("POST", "spotify/queue/play",
                              body: Body(room: room, position: position))
    }

    static func queueRemove(room: String, positions: [Int]) async throws {
        struct Body: Encodable { let room: String; let positions: [Int] }
        struct Reply: Decodable { let removed: [Int] }
        let _: Reply = try await send("POST", "spotify/queue/remove",
                                      body: Body(room: room, positions: positions))
    }

    static func queueReorder(room: String, from: Int, insertBefore: Int) async throws {
        struct Body: Encodable { let room: String; let fromPosition: Int; let insertBefore: Int }
        struct Reply: Decodable { let moved: Int; let before: Int }
        let _: Reply = try await send("POST", "spotify/queue/reorder",
                                      body: Body(room: room, fromPosition: from, insertBefore: insertBefore))
    }

    // MARK: Playlists

    static func playlists() async throws -> [PlaylistItem] {
        struct Reply: Decodable { let items: [PlaylistItem] }
        let reply: Reply = try await get("spotify/playlists")
        return reply.items
    }

    // MARK: House (Sonos rooms → speaker outputs)

    struct Room: Decodable {
        let name: String
        let coordinatorName: String
        let members: [String]
    }

    static func rooms() async throws -> [Room] {
        try await get("rooms")
    }

    // MARK: Apple TV (hub-paired via pyatv; commands name a device identifier)

    struct TVDevice: Decodable, Identifiable {
        let name: String
        let identifier: String
        let address: String
        let model: String
        let paired: Bool
        let room: String?      // the mapped room name (admin-set); nil = unmapped
        /// Hub-enforced: this TV is excluded from control. The hub refuses
        /// commands to it regardless; the app just doesn't offer it.
        let protected: Bool?
        var isProtected: Bool { protected == true }
        var id: String { identifier }
    }

    /// One flat snapshot from the TV. `app` is the app currently playing
    /// media; idle TVs report nil even with an app on screen.
    struct TVStatus: Decodable {
        let identifier: String
        let power: String          // "on" | "off"
        let app: String?
        let state: String
        let title: String?
        /// Seconds. Present only while an app has an active now-playing
        /// session; an idle home screen reports neither.
        let position: Int?
        let totalTime: Int?
        let can: TVCan?
        var isOn: Bool { power == "on" }
        var isPlaying: Bool { state == "playing" }
    }

    /// What the current app on screen honours. tvOS apps differ: Hulu skips
    /// but ignores absolute seek, others do both.
    struct TVCan: Decodable {
        let seek: Bool
        let skipForward: Bool
        let skipBackward: Bool
        let playPause: Bool
    }

    struct TVApp: Decodable, Identifiable, Hashable {
        let name: String
        let id: String
    }

    static func tvDevices() async throws -> [TVDevice] {
        // The hub scans the LAN to answer this (~5s). The default 6s request
        // window is too tight once resolve time is added, so widen it here.
        var request = URLRequest(url: baseURL.appendingPathComponent("tv/devices"))
        request.timeoutInterval = 12
        return try await run(request)
    }

    static func tvStatus(_ identifier: String) async throws -> TVStatus {
        try await get("tv/\(identifier)/status")
    }

    static func tvPower(_ identifier: String, on: Bool) async throws {
        struct Ack: Decodable { let power: String }
        let _: Ack = try await send("POST", "tv/\(identifier)/power/\(on ? "on" : "off")")
    }

    static func tvApps(_ identifier: String) async throws -> [TVApp] {
        try await get("tv/\(identifier)/apps")
    }

    static func tvLaunch(_ identifier: String, app: String) async throws {
        struct Ack: Decodable { let launched: String }
        let _: Ack = try await send("POST", "tv/\(identifier)/launch/\(app)")
    }

    /// button ∈ up/down/left/right/select/menu/home/play_pause/…
    /// `seconds` only applies to skip_forward / skip_backward; without it
    /// the app picks its own interval (often 15 or 30s, not 10).
    static func tvKey(_ identifier: String, _ button: String,
                      seconds: Double? = nil) async throws {
        struct Ack: Decodable { let pressed: String }
        var path = "tv/\(identifier)/key/\(button)"
        if let seconds { path += "?seconds=\(seconds)" }
        let _: Ack = try await send("POST", path)
    }

    /// Jump to an absolute position (seconds). Returns false when the app
    /// silently ignored it. The hub checks where playback actually landed,
    /// because the protocol's "supported" flag can't be trusted per-app.
    @discardableResult
    static func tvSeek(_ identifier: String, to position: Int) async throws -> Bool {
        struct Ack: Decodable { let applied: Bool }
        let ack: Ack = try await send("POST", "tv/\(identifier)/seek",
                                      body: ["position": position])
        return ack.applied
    }

    /// Now-playing artwork for a TV room; `key` busts AsyncImage's cache
    /// when the playing title changes.
    static func tvArtworkURL(_ room: String, key: String) -> String {
        let encoded = room.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? room
        return "\(baseURL)/tv/\(encoded)/artwork?v=\(key.hashValue)"
    }

    /// Type into the TV's focused text field (409 when none has focus).
    /// Replaces the whole field, so live sync just resends the string.
    static func tvText(_ identifier: String, _ text: String) async throws {
        struct Ack: Decodable { let text: String }
        let _: Ack = try await send("POST", "tv/\(identifier)/text",
                                    body: ["text": text])
    }

    // MARK: Auth (PIN → hub token; enforcement lives on the hub)

    /// Bearer token for the signed-in profile. Set at login, cleared at
    /// sign-out; every request carries it once present. Persisted so a
    /// relaunch has it immediately: the fresh login replaces it in the
    /// background, and commands issued in the first seconds don't 401.
    static var authToken: String? = UserDefaults.standard.string(forKey: "console.hubtoken") {
        didSet {
            if let authToken {
                UserDefaults.standard.set(authToken, forKey: "console.hubtoken")
            } else {
                UserDefaults.standard.removeObject(forKey: "console.hubtoken")
            }
        }
    }

    private struct TokenReply: Decodable { let token: String }

    /// Exchange the local PIN for the hub's API token.
    static func login(name: String, pin: String) async throws -> String {
        let reply: TokenReply = try await send(
            "POST", "login", body: ["name": name, "pin": pin])
        return reply.token
    }

    struct PinLoginReply: Decodable {
        let name: String
        let role: String
        let token: String
    }

    /// PIN-only login: the hub's DB resolves who the PIN belongs to, so the
    /// app never ships a user roster. 401 = wrong PIN; anything else = hub
    /// trouble (the login screen treats those differently).
    static func loginPin(_ pin: String) async throws -> PinLoginReply {
        try await send("POST", "login/pin", body: ["pin": pin])
    }

    /// Keep the hub's PIN in step with an app-side passcode change.
    static func changeOwnPin(_ pin: String) async throws {
        struct Ack: Decodable { let ok: Bool }
        let _: Ack = try await send(
            "PUT", "users/me/pin", body: ["name": "", "pin": pin])
    }

    // MARK: Admin (hub lifecycle, driven from the Profile page)

    private struct AdminAck: Decodable { let ok: Bool }
    private struct Health: Decodable { let status: String }

    /// Bounce the hub: it re-execs in place and comes back in ~2s.
    static func adminRestart() async throws {
        let _: AdminAck = try await send("POST", "admin/restart")
    }

    /// Force-stop the hub. One-way: starting again requires the Mac.
    static func adminStop() async throws {
        let _: AdminAck = try await send("POST", "admin/stop")
    }

    /// Lightweight reachability probe.
    static func healthOK() async -> Bool {
        let h: Health? = try? await get("health")
        return h?.status == "ok"
    }

    /// Health probe with round-trip latency. nil = hub unreachable.
    /// Single attempt, short timeout, no retry: the number shown to the
    /// user must be one real round trip, and a down hub must cost this
    /// poll 2s, not a retried 12.
    static func healthPing() async -> Int? {
        var request = URLRequest(url: baseURL.appendingPathComponent("health"))
        request.timeoutInterval = 2
        let start = Date.now
        guard let h: Health = try? await runOnce(request), h.status == "ok" else { return nil }
        return Int(Date.now.timeIntervalSince(start) * 1000)
    }

    struct AdminInfo: Decodable { let network: String }

    /// Hub identity (network name) for the Profile page.
    static func adminInfo() async throws -> AdminInfo {
        try await get("admin/info")
    }

    // MARK: Hubkeeper (always-on supervisor on the hub machine)
    // The hub can't start itself once stopped, since nothing is listening.
    // The keeper (kept alive by launchd, port 8001) can. It shares the hub's
    // host, so a hub found at any address can also be restarted.

    static var keeperURL: URL { url(port: 8001) }

    struct KeeperState: Decodable { let ok: Bool; let hubRunning: Bool }

    /// Ask the keeper to start a stopped hub. Throws if the keeper itself
    /// is unreachable (keeper down = check the Mac).
    static func keeperStart() async throws -> KeeperState {
        var request = URLRequest(url: keeperURL.appendingPathComponent("start"))
        request.httpMethod = "POST"
        return try await run(request)
    }

    // MARK: Transport plumbing (snake_case JSON both ways)

    private static func get<T: Decodable>(
        _ path: String, query: [URLQueryItem] = []
    ) async throws -> T {
        var comps = URLComponents(
            url: baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )!
        if !query.isEmpty { comps.queryItems = query }
        let request = URLRequest(url: comps.url!)
        return try await run(request)
    }

    private static func send<T: Decodable>(
        _ method: String, _ path: String, body: (some Encodable)? = nil as String?
    ) async throws -> T {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        if let body {
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            request.httpBody = try encoder.encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return try await run(request)
    }

    private struct ErrorBody: Decodable { let detail: String }

    private static func run<T: Decodable>(_ request: URLRequest) async throws -> T {
        do {
            return try await runOnce(request)
        } catch let error as URLError where (request.httpMethod ?? "GET") == "GET"
            && [.networkConnectionLost, .timedOut, .cannotConnectToHost].contains(error.code) {
            // GETs are idempotent: one immediate retry replaces the stale
            // pooled socket a roam left behind. Mutations never auto-retry
            // (a re-sent "next" would double-skip).
            return try await runOnce(request)
        }
    }

    private static func runOnce<T: Decodable>(_ request: URLRequest) async throws -> T {
        guard let host = request.url?.host(), !host.isEmpty else {
            throw URLError(.cannotFindHost)
        }
        var request = request
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, resp) = try await session.data(for: request)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let detail = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.detail
            throw Error(status: status, detail: detail ?? "hub error \(status)")
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
    }
}
