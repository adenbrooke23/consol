import SwiftUI

@main
struct ConsoleApp: App {
    @State private var auth: AuthStore
    @State private var sessions: SessionStore

    init() {
        FontRegistrar.register()
        // The stage starts empty: sessions exist only when the user
        // creates them, and nothing claims to play until the hub confirms it.
        let auth = AuthStore()
        var sessions = SessionStore(sessions: [])
        #if DEBUG
        // Screenshot/verification hooks driven by env vars (SIMCTL_CHILD_*):
        //   UITEST_SESSIONS=<n>   start with n cards (0…6)
        //   UITEST_AUTOLOGIN=1    skip the PIN screen
        //   UITEST_CREATING=1     open the chooser on appear
        let env = ProcessInfo.processInfo.environment
        if let n = env["UITEST_SESSIONS"], let count = Int(n) {
            sessions = SessionStore(sessions: MockData.fixture(count: count))
            sessions.persistenceEnabled = false   // mock fixtures never persist
        }
        if env["UITEST_CREATING"] == "1" { sessions.debugAutoOpenChooser = true }
        if let b = env["UITEST_BAR"], let i = Int(b), sessions.sessions.indices.contains(i) {
            sessions.barID = sessions.sessions[i].id
        }
        // UITEST_PAUSED=<i>: mark session i paused, so the TV transport's
        // paused state is screenshot-verifiable without a real Apple TV.
        if let p = env["UITEST_PAUSED"], let i = Int(p), sessions.sessions.indices.contains(i) {
            sessions.sessions[i].isLive = false
        }
        if let f = env["UITEST_FOCUS"], let i = Int(f), sessions.sessions.indices.contains(i) {
            sessions.focusedID = sessions.sessions[i].id
            sessions.barID = sessions.sessions[i].id
        }
        if let rooms = env["UITEST_FRESH_MUSIC"] {
            // A real fresh session on named room(s). "A|B" creates a real
            // Sonos group, idle until something plays.
            let outputs = rooms.split(separator: "|").map { Output(String($0), .speaker) }
            let s = sessions.create(kind: .music, on: outputs)
            sessions.focusedID = s.id
            sessions.barID = s.id
            if env["UITEST_FULLSCREEN"] == "1" { sessions.fullscreen = s.id }
        }
        // UITEST_FRESH_TV=<room>: a real Apps session on a mapped TV room, so
        // TV transport can be checked against actual hardware. This powers
        // the TV on, exactly as the chooser would.
        if let room = env["UITEST_FRESH_TV"] {
            let s = sessions.create(kind: .apps, on: [Output(room, .tv)])
            sessions.barID = s.id
        }
        if let aid = env["UITEST_BROWSE_ARTIST"] {
            sessions.browse = BrowseTarget(kind: .artist, spotifyID: aid, title: "Artist", image: nil)
        }
        if let alid = env["UITEST_BROWSE_ALBUM"] {
            sessions.browse = BrowseTarget(kind: .album, spotifyID: alid, title: "Album", image: nil)
        }
        // The runtime roster lives in the hub's database. Autologin borrows
        // the first fixture profile, so authorized commands need a hub user
        // with the same name and PIN.
        if env["UITEST_AUTOLOGIN"] == "1", let first = MockData.family.first {
            auth.commit(first)
        }
        #endif
        // Cards survive relaunch: restore persisted sessions (kind + rooms);
        // the per-room poll repaints now-playing within seconds.
        sessions.restoreSessions()
        _auth = State(initialValue: auth)
        _sessions = State(initialValue: sessions)
    }

    var body: some Scene {
        WindowGroup {
            content
                .task { HubDiscovery.startIfEnabled() }   // find the hub before login needs it
                .environment(auth)
                .environment(sessions)
                .preferredColorScheme(.dark)
                .animation(.easeInOut(duration: 0.3), value: isLoggedIn)
                .background(KeyboardDismissInstaller())   // tap outside a field = keyboard down
                // App-wide break glass: quitting the app silences every room
                // it controls (same rule as closing a card).
                .onReceive(NotificationCenter.default.publisher(
                    for: UIApplication.willTerminateNotification)) { _ in
                    sessions.panicStopAll(rooms: sessions.musicRooms)
                }
        }
    }

    private var isLoggedIn: Bool {
        if case .loggedIn = auth.state { return true }
        return false
    }

    @ViewBuilder private var content: some View {
        if isLoggedIn {
            RootShellView().transition(.opacity)
        } else {
            LoginView().transition(.opacity)
        }
    }
}
