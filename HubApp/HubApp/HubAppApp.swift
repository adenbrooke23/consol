import SwiftUI

// CONSOL Hub: the Mac side of the house. One window: install the hub if this
// Mac doesn't run it yet, otherwise act as its control panel. The app holds no
// hub logic itself. The hub (FastAPI, port 8000) and its keeper (port 8001)
// stay authoritative; this is a front end for them, like the iPad app.

@main
struct HubAppApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
                .frame(minWidth: 1000, minHeight: 660)
        }
    }
}
