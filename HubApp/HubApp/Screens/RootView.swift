import SwiftUI

// One decision: does this Mac already run the hub? Ports answering (or an
// installed keeper plist) → dashboard; a truly bare Mac → installer wizard.

struct RootView: View {
    @State private var monitor = StackMonitor()
    @State private var installer = HubInstaller()

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            switch monitor.phase {
            case .checking:
                VStack(spacing: Theme.Space.s5) {
                    Wordmark()
                    Text("Checking this Mac…")
                        .typo(.caption).foregroundStyle(Theme.ink2)
                }
            case .needsInstall:
                WizardView(installer: installer, monitor: monitor)
            case .ready:
                DashboardView(monitor: monitor, installer: installer)
            }
        }
        .task { await monitor.bootstrap() }
    }
}
