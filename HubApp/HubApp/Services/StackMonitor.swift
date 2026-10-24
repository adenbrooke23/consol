import Foundation
import Observation

// What the dashboard knows about the running stack. The ports are the source
// of truth, the same rule the keeper uses: no pid bookkeeping, just "does it
// answer". Reads are open; lifecycle mutations carry a hub token obtained with
// a PIN, like the iPad app.

@MainActor
@Observable
final class StackMonitor {
    enum Phase { case checking, needsInstall, ready }

    private(set) var phase: Phase = .checking
    private(set) var keeperUp = false
    private(set) var hubUp = false
    private(set) var latencyMS: Int?
    private(set) var spotifyConfigured = false
    private(set) var spotifyConnected = false
    private(set) var networkName: String?

    struct RoomStatus: Identifiable, Equatable {
        var id: String { name }
        let name: String
        let playing: Bool
        let nowPlaying: String?
    }
    private(set) var rooms: [RoomStatus] = []
    private(set) var token: String?
    private(set) var authedName: String?
    private(set) var authedRole: String?
    private(set) var lastActionError: String?
    private(set) var busy = false

    struct HubUser: Identifiable, Equatable {
        let id: Int
        let name: String
        let role: String
        let locked: Bool
    }
    private(set) var users: [HubUser] = []

    static let hubBase = URL(string: "http://127.0.0.1:8000")!
    static let keeperBase = URL(string: "http://127.0.0.1:8001")!

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 4
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }()

    // MARK: - Polling

    /// First look decides install-vs-dashboard; after that the poll only
    /// refreshes state (it never flips back to the wizard mid-session).
    func bootstrap() async {
        await refresh()
        phase = (keeperUp || hubUp || HubInstaller.isInstalled) ? .ready : .needsInstall
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3))
            if phase == .ready { await refresh() }
        }
    }

    func enterDashboard() { phase = .ready }

    /// Back to the wizard: after an uninstall, or as the escape hatch when
    /// the stack is dead and there's nothing left to manage.
    func enterSetup() {
        signOut()
        phase = .needsInstall
    }

    func refresh() async {
        if let data = await get(Self.keeperBase.appendingPathComponent("health")),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            keeperUp = (obj["ok"] as? Bool) ?? false
        } else {
            keeperUp = false
        }

        let start = Date()
        if await get(Self.hubBase.appendingPathComponent("health")) != nil {
            hubUp = true
            latencyMS = Int(Date().timeIntervalSince(start) * 1000)
        } else {
            hubUp = false
            latencyMS = nil
        }

        guard hubUp else {
            rooms = []
            return
        }
        if let data = await get(Self.hubBase.appendingPathComponent("spotify/status")),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            spotifyConfigured = (obj["configured"] as? Bool) ?? false
            spotifyConnected = (obj["connected"] as? Bool) ?? false
        }
        if let data = await get(Self.hubBase.appendingPathComponent("admin/info")),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            networkName = obj["network"] as? String
        }

        // Room list from /rooms (coordinators only; a bonded twin shares its
        // room's name); live activity joined in from /now-playing.
        var activity: [String: (playing: Bool, title: String?)] = [:]
        if let data = await get(Self.hubBase.appendingPathComponent("now-playing")),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for snap in arr {
                guard let room = snap["room"] as? String else { continue }
                let playing = (snap["playing"] as? Bool) ?? false
                var title = snap["title"] as? String
                if let artist = snap["artist"] as? String, let t = title, !artist.isEmpty {
                    title = "\(t) · \(artist)"
                }
                activity[room] = (playing, title)
            }
        }
        if let data = await get(Self.hubBase.appendingPathComponent("rooms")),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            rooms = arr.compactMap { room in
                guard (room["is_coordinator"] as? Bool) == true,
                      let name = room["name"] as? String else { return nil }
                let act = activity[name]
                return RoomStatus(name: name,
                                  playing: act?.playing ?? false,
                                  nowPlaying: act?.playing == true ? act?.title : nil)
            }
        }
        if token != nil { await refreshUsers() }
    }

    private func get(_ url: URL) async -> Data? {
        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        return data
    }

    // MARK: - Auth (PIN → hub token, the same exchange the iPad makes)

    func login(name: String, pin: String) async -> Bool {
        var request = URLRequest(url: Self.hubBase.appendingPathComponent("login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["name": name, "pin": pin])
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = obj["token"] as? String else {
            lastActionError = "Wrong name or PIN."
            return false
        }
        self.token = token
        self.authedName = name
        lastActionError = nil
        await loadIdentity()
        await refreshUsers()
        return true
    }

    func signOut() {
        token = nil
        authedName = nil
        authedRole = nil
        users = []
    }

    // MARK: - Household (the hub's DB is the roster; the iPad needs no build
    // when it changes, since its login asks the hub who a PIN belongs to)

    private func loadIdentity() async {
        guard let data = await authedGet(Self.hubBase.appendingPathComponent("me")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        authedRole = obj["role"] as? String
    }

    func refreshUsers() async {
        guard let data = await authedGet(Self.hubBase.appendingPathComponent("users")),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return
        }
        users = arr.compactMap { u in
            guard let id = u["id"] as? Int,
                  let name = u["name"] as? String,
                  let role = u["role"] as? String else { return nil }
            return HubUser(id: id, name: name, role: role,
                           locked: (u["locked"] as? Bool) ?? false)
        }
    }

    /// Returns nil on success, else a short human error.
    func addUser(name: String, pin: String) async -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "Needs a name." }
        guard pin.count == 4, pin.allSatisfy(\.isNumber) else { return "The PIN must be 4 digits." }
        let error = await authedSend(
            "POST", Self.hubBase.appendingPathComponent("users"),
            body: ["name": trimmed, "role": "member", "pin": pin])
        await refreshUsers()
        return error
    }

    func removeUser(name: String) async -> String? {
        let error = await authedSend(
            "DELETE",
            Self.hubBase.appendingPathComponent("users").appendingPathComponent(name))
        await refreshUsers()
        return error
    }

    /// Admin resets someone's PIN.
    func resetPin(name: String, pin: String) async -> String? {
        guard pin.count == 4, pin.allSatisfy(\.isNumber) else { return "The PIN must be 4 digits." }
        return await authedSend(
            "PUT",
            Self.hubBase.appendingPathComponent("users")
                .appendingPathComponent(name).appendingPathComponent("pin"),
            body: ["pin": pin])
    }

    /// Lock = login refused and the existing token goes dead; row kept.
    func setLocked(name: String, locked: Bool) async -> String? {
        let error = await authedSend(
            "POST",
            Self.hubBase.appendingPathComponent("users")
                .appendingPathComponent(name)
                .appendingPathComponent(locked ? "lock" : "unlock"))
        await refreshUsers()
        return error
    }

    /// The name the household sees on the iPad; stored in the hub's DB.
    func setNetwork(_ name: String) async -> String? {
        let error = await authedSend(
            "PUT", Self.hubBase.appendingPathComponent("admin/network"),
            body: ["name": name])
        await refresh()
        return error
    }

    /// Tail of what the stack writes (admin): source = "hub" | "keeper".
    func fetchLogs(source: String, lines: Int = 200) async -> [String] {
        var comps = URLComponents(
            url: Self.hubBase.appendingPathComponent("admin/logs"),
            resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "source", value: source),
                            URLQueryItem(name: "lines", value: String(lines))]
        guard let url = comps.url, let data = await authedGet(url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        return (obj["lines"] as? [String]) ?? []
    }

    /// Wi-Fi networks this Mac remembers, offered as network-name candidates.
    nonisolated static func preferredWifiNetworks() -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        process.arguments = ["-listpreferredwirelessnetworks", "en0"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let out = String(data: data, encoding: .utf8) else { return [] }
        return out.split(separator: "\n").dropFirst()
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func authedGet(_ url: URL) async -> Data? {
        guard let token else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        return data
    }

    /// Returns nil on 2xx, else the hub's `detail` (or a fallback).
    private func authedSend(_ method: String, _ url: URL,
                            body: [String: Any]? = nil) async -> String? {
        guard let token else { return "Sign in first." }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else {
            return "No answer from the hub."
        }
        if (200..<300).contains(http.statusCode) { return nil }
        let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
            .flatMap { $0["detail"] as? String }
        return detail ?? "Request failed (\(http.statusCode))."
    }

    // MARK: - Lifecycle actions

    func startHub() async {
        if keeperUp && token != nil {
            await post(Self.keeperBase.appendingPathComponent("start"))
        } else {
            // No token (a dead hub can't mint one) or no keeper: have launchd
            // relaunch the keeper; its autostart brings the hub up without auth.
            busy = true
            await HubInstaller.kickstartKeeper()
            try? await Task.sleep(for: .seconds(3))
            busy = false
        }
        await refresh()
    }

    func stopHub() async {
        await post(Self.keeperBase.appendingPathComponent("stop"))
        await refresh()
    }

    func restartHub() async {
        await post(Self.hubBase.appendingPathComponent("admin/restart"))
        try? await Task.sleep(for: .seconds(2))
        await refresh()
    }

    private func post(_ url: URL) async {
        guard let token else {
            lastActionError = "Sign in first."
            return
        }
        busy = true
        defer { busy = false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else {
            lastActionError = "No answer from the hub."
            return
        }
        if (200..<300).contains(http.statusCode) {
            lastActionError = nil
        } else if http.statusCode == 401 {
            lastActionError = "Session expired. Sign in again."
            self.token = nil
        } else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { $0["detail"] as? String }
            lastActionError = detail ?? "Request failed (\(http.statusCode))."
        }
    }
}
