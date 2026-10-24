import SwiftUI

// Four fixed tabs (Stage · Search · Devices · Profile). Compact width (iPhone):
// a native bottom TabView (structural only). Regular width (iPad):
// a container-less vertical tab column that collapses to a 4×36pt edge handle;
// tap the handle or swipe from the left edge to bloom the tabs, tap the active
// tab to collapse, auto-collapse 8s after the last interaction. Content runs
// full-bleed behind the column.

enum ShellTab: String, CaseIterable, Identifiable {
    case stage, search, devices, profile
    var id: String { rawValue }
    var title: String {
        switch self {
        case .stage: "Stage"; case .search: "Search"
        case .devices: "Devices"; case .profile: "Profile"
        }
    }
    var symbol: String {
        switch self {
        case .stage: "rectangle.on.rectangle"
        case .search: "magnifyingglass"
        case .devices: "hifispeaker.and.appletv"
        case .profile: "person.crop.circle"
        }
    }
}

struct RootShellView: View {
    @Environment(\.horizontalSizeClass) private var hClass
    @Environment(\.scenePhase) private var scenePhase
    @Environment(SessionStore.self) private var store
    @Environment(AuthStore.self) private var auth
    @State private var tab: ShellTab = .stage
    @State private var expanded = false
    @State private var interaction = 0

    init() {
        #if DEBUG
        // Screenshot hook: UITEST_TAB=profile|search|devices opens that tab.
        if let t = ProcessInfo.processInfo.environment["UITEST_TAB"],
           let start = ShellTab(rawValue: t) {
            _tab = State(initialValue: start)
        }
        #endif
    }

    var body: some View {
        Group {
            if hClass == .compact {
                compactShell
            } else {
                regularShell
            }
        }
        .preferredColorScheme(.dark)
        // Full-screen now-playing sits above everything (tabs, bar, strip).
        .overlay {
            if let fid = store.fullscreen,
               let session = store.sessions.first(where: { $0.id == fid }) {
                NowPlayingView(session: session)
                    .transition(.opacity)
            }
        }
        // Real house state: outputs + playlists once. Owned here (not by a
        // tab) so it survives tab switches on iPad.
        .task { await store.loadHouse() }
        // Poll every music card's room while the scene is active. The poll is
        // also the DEBUG heartbeat: when the app stops being visible (killed,
        // simulator UI closed), polls stop and the hub's dead-man switch
        // silences the rooms. Restarts automatically on re-activation.
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                // Token repair: if login happened while the hub was down,
                // keep trying to buy the token in the background.
                await auth.fetchHubToken()
                await store.syncPlayer()
                // Health ride-along: one cheap ping per tick keeps the
                // StatusStrip dot and Profile indicators accurate. Paused
                // while a Profile hub operation runs, since its verdict wins.
                if !store.hubAdminInFlight {
                    let latency = await Hub.healthPing()
                    if !store.hubAdminInFlight {
                        store.hubLatencyMs = latency
                        store.hubOnline = latency != nil
                    }
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    @ViewBuilder private func screen(_ t: ShellTab) -> some View {
        switch t {
        case .stage: StageView()
        case .search: PlaceholderScreen(title: "Search", note: "Spotify search across the house. Results play in the room you're in, so you never have to pick where.")
        case .devices: DevicesScreen()
        case .profile: ProfileScreen()
        }
    }

    // MARK: iPhone: native bottom bar (structural only)
    private var compactShell: some View {
        TabView(selection: $tab) {
            ForEach(ShellTab.allCases) { t in
                screen(t)
                    .tabItem { Label(t.title, systemImage: t.symbol) }
                    .tag(t)
            }
        }
        .tint(Theme.signal)
    }

    // MARK: iPad: edge handle ⟷ vertical column
    private var regularShell: some View {
        ZStack(alignment: .leading) {
            screen(tab)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Tap-away scrim: while the menu is open, one tap anywhere
            // outside it closes it (and never falls through to content).
            if expanded {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { collapse() }
            }

            navColumn
                .allowsHitTesting(expanded)

            if !expanded {
                edgeHandle.transition(.opacity)
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .gesture(
            DragGesture(minimumDistance: 20)
                .onEnded { g in
                    if !expanded, g.startLocation.x < 40, g.translation.width > 40 { expand() }
                }
        )
        .task(id: interaction) {
            guard expanded else { return }
            try? await Task.sleep(for: .seconds(8))
            if !Task.isCancelled { collapse() }
        }
    }

    private var edgeHandle: some View {
        Capsule()
            .fill(Theme.ink3)
            .frame(width: 4, height: 36)
            .padding(.leading, 9)
            .frame(maxWidth: 40, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { expand() }
            .accessibilityLabel("Show navigation")
            .accessibilityAddTraits(.isButton)
    }

    private var navColumn: some View {
        VStack(spacing: Theme.Space.s2) {
            ForEach(Array(ShellTab.allCases.enumerated()), id: \.element.id) { index, t in
                VTabButton(tab: t, active: tab == t) { select(t) }
                    .opacity(expanded ? 1 : 0)
                    .offset(x: expanded ? 0 : -12)
                    .animation(Theme.Motion.tabExpand.delay(Double(index) * 0.03), value: expanded)
            }
        }
        .padding(.vertical, Theme.Space.s3)
        // The pill: a panel surface + hairline so the menu reads as an object
        // over the stage instead of loose glyphs floating on black.
        .background(
            Capsule(style: .continuous)
                .fill(Theme.surface)
                .overlay(Capsule(style: .continuous).stroke(Theme.rule, lineWidth: 1))
                .opacity(expanded ? 1 : 0)
                .animation(Theme.Motion.tabExpand, value: expanded)
        )
        .padding(.leading, Theme.Space.s3)
        .frame(maxHeight: .infinity, alignment: .center)
    }

    // MARK: Actions
    private func expand() {
        withAnimation(Theme.Motion.tabExpand) { expanded = true }
        interaction += 1
    }
    private func collapse() {
        withAnimation(Theme.Motion.tabCollapse) { expanded = false }
    }
    private func select(_ t: ShellTab) {
        if t == tab { collapse(); return }
        tab = t
        interaction += 1
    }
}

private struct VTabButton: View {
    let tab: ShellTab
    let active: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 20))
                    .foregroundStyle(active ? Theme.signal : Theme.ink2)
                Text(tab.title)
                    .font(.custom(FontStack.ui.medium, size: 10.5))
                    .foregroundStyle(active ? Theme.ink : Theme.ink2)
            }
            .frame(width: 88)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    RootShellView()
        .environment(SessionStore(sessions: MockData.sessions))
        .environment(AuthStore())
}
