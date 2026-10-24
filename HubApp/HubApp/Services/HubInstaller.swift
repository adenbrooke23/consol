import Foundation
import Observation

// Turns this Mac into the hub. The app bundles the hub source (hub-payload in
// Resources; secrets and state are excluded at build time). Installing copies
// it to Application Support, builds the venv, writes .env, seeds the household
// users, and hands lifecycle to launchd via the hubkeeper, which then owns the
// hub process.

struct SetupForm {
    var spotifyClientID = ""
    var spotifyClientSecret = ""
    var networkName = ""
    var adminName = ""
    var adminPin = ""
    var members: [MemberDraft] = []
}

struct MemberDraft: Identifiable, Equatable {
    let id = UUID()
    var name = ""
    var pin = ""
}

struct InstallError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

@MainActor
@Observable
final class HubInstaller {
    enum StepState { case pending, running, done, failed }
    struct Step: Identifiable {
        let id: String
        let title: String
        var state: StepState = .pending
    }

    static let keeperLabel = "local.consol.hubkeeper"

    static var installDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CONSOL/hub", isDirectory: true)
    }

    static var keeperPlist: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(keeperLabel).plist")
    }

    /// Installed means the keeper's launchd plist exists. Ports answering is
    /// the runtime signal; this is the durable one.
    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: keeperPlist.path)
    }

    private(set) var steps: [Step] = []
    private(set) var logLines: [String] = []
    private(set) var running = false
    private(set) var failed = false
    private(set) var finished = false

    private func log(_ line: String) {
        logLines.append(line)
        if logLines.count > 500 { logLines.removeFirst(logLines.count - 500) }
    }

    private func setState(_ id: String, _ state: StepState) {
        if let i = steps.firstIndex(where: { $0.id == id }) { steps[i].state = state }
    }

    // MARK: - The install run

    func install(_ form: SetupForm) async {
        guard !running else { return }
        running = true
        failed = false
        finished = false
        logLines = []
        steps = [
            Step(id: "copy", title: "Copy hub to this Mac"),
            Step(id: "venv", title: "Python environment"),
            Step(id: "deps", title: "Install dependencies"),
            Step(id: "env", title: "Write configuration"),
            Step(id: "zones", title: "Find your speakers"),
            Step(id: "users", title: "Create household users"),
            Step(id: "launchd", title: "Install always-on keeper"),
            Step(id: "wait", title: "Wait for the hub to answer"),
        ]
        do {
            try await step("copy") { try await self.copyPayload() }
            try await step("venv") { try await self.makeVenv() }
            try await step("deps") { try await self.installDeps() }
            try await step("env") { try self.writeEnv(form) }
            try await step("zones") { try await self.seedZones() }
            try await step("users") { try await self.seedUsers(form) }
            try await step("launchd") { try await self.installKeeper() }
            try await step("wait") { try await self.waitForHub() }
            finished = true
            log("HUB ONLINE.")
        } catch {
            failed = true
            log("FAILED: \(error.localizedDescription)")
        }
        running = false
    }

    private func step(_ id: String, _ body: () async throws -> Void) async throws {
        setState(id, .running)
        do {
            try await body()
            setState(id, .done)
        } catch {
            setState(id, .failed)
            throw error
        }
    }

    // MARK: - Steps

    private func copyPayload() async throws {
        guard let payload = Bundle.main.resourceURL?.appendingPathComponent("hub-payload"),
              FileManager.default.fileExists(atPath: payload.path) else {
            throw InstallError("hub-payload missing from the app bundle")
        }
        try FileManager.default.createDirectory(at: Self.installDir,
                                                withIntermediateDirectories: true)
        // No --delete: a reinstall must never touch data.db / .env already there.
        try await run("/usr/bin/rsync", ["-a", payload.path + "/", Self.installDir.path + "/"])
        log("hub source in \(Self.installDir.path)")
    }

    private func makeVenv() async throws {
        let venv = Self.installDir.appendingPathComponent(".venv")
        let venvPython = venv.appendingPathComponent("bin/python").path
        if FileManager.default.fileExists(atPath: venvPython) {
            if Self.isSupported(venvPython) {
                log("venv already present, keeping it")
                return
            }
            log("existing venv uses Python older than 3.10, rebuilding it")
            try FileManager.default.removeItem(at: venv)
        }
        guard let python = Self.supportedPython() else {
            throw InstallError("Python 3.10 or later is required. Install it from python.org or with Homebrew (brew install python), then run setup again.")
        }
        try await run(python, ["-m", "venv", ".venv"], cwd: Self.installDir)
    }

    // The hub needs Python 3.10 or later, and the python3 that ships with macOS is 3.9.
    // Apps opened from Finder don't inherit the shell's PATH, so look in the usual
    // install locations instead of trusting `env python3`.
    private static func supportedPython() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let versioned = (10...14).reversed().flatMap { ["/opt/homebrew/bin/python3.\($0)", "/usr/local/bin/python3.\($0)"] }
        let candidates = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3",
                          "/Library/Frameworks/Python.framework/Versions/Current/bin/python3",
                          "\(home)/.pyenv/shims/python3"] + versioned
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) && isSupported($0) }
    }

    private static func isSupported(_ python: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-c", "import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private func installDeps() async throws {
        let pip = Self.installDir.appendingPathComponent(".venv/bin/pip").path
        try await run(pip, ["install", "-q", "--upgrade", "pip"], cwd: Self.installDir)
        try await run(pip, ["install", "-q", "-r", "requirements.txt"], cwd: Self.installDir)
    }

    private func writeEnv(_ form: SetupForm) throws {
        let envURL = Self.installDir.appendingPathComponent(".env")
        let haveCreds = !form.spotifyClientID.isEmpty
        if !haveCreds && FileManager.default.fileExists(atPath: envURL.path) {
            log(".env already present, keeping it")
            return
        }
        var updates = [
            ("SPOTIFY_CLIENT_ID", form.spotifyClientID),
            ("SPOTIFY_CLIENT_SECRET", form.spotifyClientSecret),
        ]
        if !form.networkName.isEmpty { updates.append(("NETWORK_NAME", form.networkName)) }
        // Merge by key: the keys above are updated in place and every other
        // line (PROTECTED_APPLE_TVS, comments) is kept as is. Values are
        // written unquoted because the hub's loader doesn't strip quotes.
        var lines = ((try? String(contentsOf: envURL, encoding: .utf8)) ?? "")
            .components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        for (key, value) in updates {
            if let i = lines.firstIndex(where: { Self.envKey($0) == key }) {
                lines[i] = "\(key)=\(value)"
            } else {
                lines.append("\(key)=\(value)")
            }
        }
        try (lines.joined(separator: "\n") + "\n")
            .write(to: envURL, atomically: true, encoding: .utf8)
        log(haveCreds ? "wrote .env (Spotify creds + network)" : "wrote empty .env; link Spotify later")
    }

    /// The key of a `KEY=value` line, parsed the way the hub's loader does;
    /// nil for comments and blank lines.
    private static func envKey(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") else { return nil }
        return trimmed[..<eq].trimmingCharacters(in: .whitespaces)
    }

    private func seedZones() async throws {
        // launchd processes can't multicast (macOS local-network privacy), so
        // a keeper-spawned hub can only find speakers from IPs saved in the
        // DB. This app is a GUI process and is allowed to discover, so it does
        // that once here, in the hub's own shape ({room name: ip}), and the hub
        // starts already knowing the house. Zero speakers is a warning, not a
        // failure: one live IP later is enough to recover everything.
        let script = """
        import json
        import db, soco
        zones = soco.discover(timeout=8) or set()
        ips = {z.player_name.strip().lower(): z.ip_address for z in zones}
        db.init_db()
        if ips:
            db.set_secret("sonos_zone_ips", json.dumps(ips))
        print(f"found {len(ips)} speaker group(s)"
              + (": " + ", ".join(sorted(ips)) if ips else ""))
        """
        let seedURL = Self.installDir.appendingPathComponent("_seed_zones.py")
        try script.write(to: seedURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: seedURL) }
        let python = Self.installDir.appendingPathComponent(".venv/bin/python").path
        let output = try await run(python, ["_seed_zones.py"], cwd: Self.installDir)
        if output.contains("found 0") {
            log("WARNING: no speakers answered. If this Mac just asked for local")
            log("network permission, allow it and run the install again. The hub")
            log("still works, and rooms appear once a speaker is reachable.")
        }
    }

    private func seedUsers(_ form: SetupForm) async throws {
        var users: [[String: String]] = [
            ["name": form.adminName, "pin": form.adminPin, "role": "admin"]
        ]
        for m in form.members where !m.name.isEmpty {
            users.append(["name": m.name, "pin": m.pin, "role": "member"])
        }
        let json = try JSONSerialization.data(withJSONObject: users)
        let script = """
        import json, os
        import auth, db
        db.init_db()
        users = json.loads(os.environ["SEED_USERS"])
        conn = db.get_conn()
        try:
            for u in users:
                max_vol = auth.DEFAULT_KID_MAX_VOLUME if u["role"] == "kid" else None
                conn.execute(
                    "INSERT INTO users (name, role, pin_hash, api_token, max_volume) "
                    "VALUES (?,?,?,?,?) ON CONFLICT(name) DO UPDATE SET "
                    "role=excluded.role, pin_hash=excluded.pin_hash",
                    (u["name"], u["role"], auth.hash_pin(u["pin"]), auth.new_token(), max_vol))
            conn.commit()
        finally:
            conn.close()
        print(f"seeded {len(users)} user(s)")
        """
        let seedURL = Self.installDir.appendingPathComponent("_seed_users.py")
        try script.write(to: seedURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: seedURL) }
        let python = Self.installDir.appendingPathComponent(".venv/bin/python").path
        try await run(python, ["_seed_users.py"], cwd: Self.installDir,
                      env: ["SEED_USERS": String(data: json, encoding: .utf8)!])
    }

    private func installKeeper() async throws {
        let dir = Self.installDir.path
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \t<key>Label</key>
        \t<string>\(Self.keeperLabel)</string>
        \t<key>ProgramArguments</key>
        \t<array>
        \t\t<string>\(dir)/.venv/bin/python</string>
        \t\t<string>\(dir)/hubkeeper.py</string>
        \t</array>
        \t<key>WorkingDirectory</key>
        \t<string>\(dir)</string>
        \t<key>RunAtLoad</key>
        \t<true/>
        \t<key>KeepAlive</key>
        \t<true/>
        \t<key>StandardOutPath</key>
        \t<string>\(dir)/hubkeeper.log</string>
        \t<key>StandardErrorPath</key>
        \t<string>\(dir)/hubkeeper.log</string>
        </dict>
        </plist>
        """
        try FileManager.default.createDirectory(
            at: Self.keeperPlist.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try plist.write(to: Self.keeperPlist, atomically: true, encoding: .utf8)
        let domain = "gui/\(getuid())"
        // bootout fails harmlessly when the agent isn't loaded yet.
        _ = try? await run("/bin/launchctl", ["bootout", "\(domain)/\(Self.keeperLabel)"])
        try await run("/bin/launchctl", ["bootstrap", domain, Self.keeperPlist.path])
        log("keeper installed; launchd keeps it alive across reboots")
    }

    private func waitForHub() async throws {
        for _ in 0..<60 {
            if await portAnswers(8000) {
                return
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw InstallError("hub did not answer on port 8000. See \(Self.installDir.path)/hub.log")
    }

    private func portAnswers(_ port: Int) async -> Bool {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/health")!)
        request.timeoutInterval = 2
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return http.statusCode == 200
    }

    // MARK: - Process plumbing

    @discardableResult
    private func run(_ tool: String, _ args: [String],
                     cwd: URL? = nil, env extra: [String: String] = [:]) async throws -> String {
        log("$ \(([tool.components(separatedBy: "/").last ?? tool] + args).joined(separator: " "))")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        if let cwd { process.currentDirectoryURL = cwd }
        var environment = ProcessInfo.processInfo.environment
        extra.forEach { environment[$0.key] = $0.value }
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data: Data = await Task.detached {
            let d = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return d
        }.value
        let output = String(data: data, encoding: .utf8) ?? ""
        for line in output.split(separator: "\n") where !line.isEmpty {
            log(String(line))
        }
        guard process.terminationStatus == 0 else {
            throw InstallError("\(tool.components(separatedBy: "/").last ?? tool) exited \(process.terminationStatus)")
        }
        return output
    }

    // MARK: - Uninstall

    /// Take the stack off this Mac: stop the hub (through the keeper, with the
    /// caller's token), remove the keeper from launchd, delete its plist, and
    /// delete the managed install, database and all. A development checkout
    /// is never touched: only ~/Library/Application Support/CONSOL/hub is
    /// removable. Returns nil on success, else a short human error.
    func uninstall(token: String?) async -> String? {
        // 1) Ask the keeper to stop the hub (best-effort; a dead keeper or
        //    hub just means there's nothing to stop).
        if let token {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:8001/stop")!)
            request.httpMethod = "POST"
            request.timeoutInterval = 15
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            _ = try? await URLSession.shared.data(for: request)
        }
        // 2) launchd lets go of the keeper (KeepAlive dies with the bootout).
        _ = try? await run("/bin/launchctl",
                           ["bootout", "gui/\(getuid())/\(Self.keeperLabel)"])
        // 3) The plist and the managed install go away.
        try? FileManager.default.removeItem(at: Self.keeperPlist)
        let managed = Self.installDir
        if FileManager.default.fileExists(atPath: managed.path) {
            do {
                try FileManager.default.removeItem(at: managed)
            } catch {
                return "Couldn't delete \(managed.path): \(error.localizedDescription)"
            }
        }
        // 4) Verify the hub actually died (a hand-started uvicorn would survive).
        try? await Task.sleep(for: .seconds(1))
        if await portAnswers(8000) {
            return "The hub still answers on port 8000. It was started outside launchd, so stop that process by hand."
        }
        return nil
    }

    /// Kick a loaded-but-dead keeper (dashboard rescue when port 8001 is silent).
    static func kickstartKeeper() async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["kickstart", "-k", "gui/\(getuid())/\(keeperLabel)"]
        try? process.run()
        process.waitUntilExit()
    }
}
