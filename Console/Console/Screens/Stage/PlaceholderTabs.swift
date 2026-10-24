import SwiftUI

// PlaceholderScreen stands in for tabs that aren't built yet (a centered
// label). ProfileScreen carries sign-out, hub controls and the debug fixture
// toggle.

struct PlaceholderScreen: View {
    var title: String
    var note: String

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(spacing: Theme.Space.s3) {
                Text(title).typo(.title).foregroundStyle(Theme.ink)
                Text(note).typo(.body).foregroundStyle(Theme.ink2)
                    .multilineTextAlignment(.center).frame(maxWidth: 340)
            }
            .padding(Theme.Space.s6)
        }
    }
}

struct ProfileScreen: View {
    @Environment(AuthStore.self) private var auth
    @Environment(SessionStore.self) private var store

    @State private var changingPasscode = false
    @State private var confirmingStop = false
    @State private var hubBusy = false
    @State private var notice: Notice?
    @State private var network: String?
    @State private var hubAddress: String = Hub.host

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            // One column: title → cards → flexible gap → attribution footer.
            // The footer flows below the content, so a tall card column can
            // never collide with it.
            VStack(spacing: Theme.Space.s4) {
                Spacer(minLength: Theme.Space.s4)
                Text(auth.currentProfile?.name ?? "Profile")
                    .typo(.display).foregroundStyle(Theme.ink)
                    .padding(.bottom, Theme.Space.s2)

                card("PROFILE") {
                    OptionRow(icon: "key", label: "Change passcode",
                              trailing: nil, trailingColor: Theme.ink3, selected: false) {
                        withAnimation(Theme.Motion.snappy) { changingPasscode = true }
                    }
                    OptionRow(icon: "rectangle.portrait.and.arrow.right", label: "Sign out",
                              trailing: nil, trailingColor: Theme.ink3, selected: false) {
                        auth.signOut()
                    }
                    #if DEBUG
                    OptionRow(icon: "wrench.and.screwdriver",
                              label: store.isEmpty ? "Load 3 sessions" : "Clear stage",
                              trailing: "DEBUG", trailingColor: Theme.ink3, selected: false) {
                        store.toggleFixture()
                    }
                    #endif
                }

                // Hub lifecycle. Restart bounces the service in place (~2s;
                // music keeps playing because the speakers stream on their
                // own). Stop is one-way: starting again requires the Mac.
                card("HUB") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(store.hubOnline ? Theme.online : Theme.alert)
                            .frame(width: 6, height: 6)
                        Text(store.hubOnline ? "Hub Online" : "Hub Offline")
                            .typo(.label)
                            .foregroundStyle(store.hubOnline ? Theme.ink2 : Theme.alert)
                        Spacer(minLength: 0)
                        if let ms = store.hubLatencyMs {
                            Text("\(ms) MS")
                                .font(.custom(FontStack.mono.regular, size: 9.5))
                                .tracking(0.1 * 9.5)
                                .foregroundStyle(Theme.ink3)
                        }
                    }
                    .padding(.horizontal, Theme.Space.s2)
                    .padding(.bottom, Theme.Space.s1)
                    if store.hubOnline {
                        OptionRow(icon: "arrow.clockwise", label: "Restart hub",
                                  trailing: hubBusy ? "WORKING" : nil,
                                  trailingColor: Theme.signal, selected: false) {
                            if !hubBusy { restartHub() }
                        }
                        OptionRow(icon: "power", label: "Stop hub",
                                  trailing: nil, trailingColor: Theme.ink3, selected: false) {
                            if !hubBusy {
                                withAnimation(Theme.Motion.snappy) { confirmingStop = true }
                            }
                        }
                    } else {
                        // A dead hub can't answer; the keeper (always-on
                        // supervisor on the Mac) starts it back up.
                        OptionRow(icon: "play", label: "Start hub",
                                  trailing: hubBusy ? "WORKING" : nil,
                                  trailingColor: Theme.signal, selected: false) {
                            if !hubBusy { startHub() }
                        }
                    }
                }

                card("NETWORK") {
                    HStack(spacing: Theme.Space.s3) {
                        Image(systemName: "wifi")
                            .font(.system(size: 16))
                            .foregroundStyle(Theme.ink2)
                            .frame(width: 28)
                        Text(network ?? "—")
                            .font(.custom(FontStack.ui.medium, size: 14))
                            .foregroundStyle(Theme.ink)
                        Spacer(minLength: 0)
                        SignalBars(latencyMs: store.hubOnline ? store.hubLatencyMs : nil)
                    }
                    .padding(Theme.Space.s3)
                    Text(networkDetail)
                        .font(.custom(FontStack.mono.regular, size: 9.5))
                        .tracking(0.1 * 9.5)
                        .foregroundStyle(Theme.ink3)
                        .padding(.horizontal, Theme.Space.s2)

                    // The hub normally announces itself (Bonjour) and this
                    // fills in alone; the field is the escape hatch for
                    // networks where discovery can't work.
                    HStack(spacing: Theme.Space.s3) {
                        Image(systemName: "server.rack")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.ink2)
                            .frame(width: 28)
                        TextField("", text: $hubAddress,
                                  prompt: Text("Hub address").foregroundStyle(Theme.ink3))
                            .font(.custom(FontStack.mono.regular, size: 12))
                            .foregroundStyle(Theme.ink)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            .onSubmit {
                                Hub.host = hubAddress
                                hubAddress = Hub.host   // reflect normalization
                                notice = Notice(text: Hub.host.isEmpty
                                                ? "Hub address cleared"
                                                : "Hub address set to \(Hub.host)")
                            }
                        Spacer(minLength: 0)
                    }
                    .padding(Theme.Space.s3)
                    Text("FOUND AUTOMATICALLY. EDIT ONLY IF THE HUB CAN'T BE FOUND.")
                        .font(.custom(FontStack.mono.regular, size: 9.5))
                        .tracking(0.1 * 9.5)
                        .foregroundStyle(Theme.ink3)
                        .padding(.horizontal, Theme.Space.s2)
                }

                Spacer(minLength: Theme.Space.s4)

                // About + attribution: full Spotify logo (brand guidelines;
                // the in-card icons roll up to this) over the app fine print.
                VStack(spacing: Theme.Space.s3) {
                    Text("MUSIC, PODCASTS & AUDIOBOOKS FROM")
                        .font(.custom(FontStack.mono.regular, size: 9.5))
                        .tracking(0.12 * 9.5)
                        .foregroundStyle(Theme.ink3)
                    Image("SpotifyFullLogo")
                        .resizable().scaledToFit()
                        .frame(height: 24)
                        .accessibilityLabel("Spotify")
                    Text("CONSOL \(Self.version) (\(Self.build)) · SPOTIFY WEB API · HUB \(Hub.baseURL.host() ?? "")")
                        .font(.custom(FontStack.mono.regular, size: 9.5))
                        .tracking(0.12 * 9.5)
                        .foregroundStyle(Theme.ink3)
                        .padding(.top, Theme.Space.s2)
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, Theme.Space.s5)
            }
            .frame(maxWidth: 480)
        }
        // Same toast capsule as the stage, so notices look alike everywhere.
        .overlay(alignment: .bottom) {
            if let notice {
                Text(notice.text)
                    .font(.custom(FontStack.mono.medium, size: 10))
                    .tracking(0.1 * 10)
                    .foregroundStyle(notice.isError ? Theme.ink : Theme.onSignal)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.vertical, Theme.Space.s2)
                    .padding(.horizontal, Theme.Space.s3)
                    .background(notice.isError ? Theme.alert : Theme.signal)
                    .clipShape(Capsule())
                    .frame(maxWidth: 560)
                    .padding(.bottom, 108)
                    .transition(.opacity)
            }
        }
        .task(id: notice) {
            // Transient like the stage's capsule, but never dismissed while working.
            guard notice != nil, !hubBusy else { return }
            try? await Task.sleep(for: .seconds(2.4))
            withAnimation(Theme.Motion.snappy) { notice = nil }
        }
        .task {
            network = (try? await Hub.adminInfo())?.network
        }
        #if DEBUG
        // Screenshot hook: UITEST_PANEL=passcode|stophub presents the panel.
        .onAppear {
            switch ProcessInfo.processInfo.environment["UITEST_PANEL"] {
            case "passcode": changingPasscode = true
            case "stophub": confirmingStop = true
            default: break
            }
        }
        #endif
        // Panels present in place, chooser-style: dimmed stage behind a black
        // pill. No system sheet chrome anywhere.
        .overlay {
            if changingPasscode || confirmingStop {
                Color.black.opacity(0.5).ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(Theme.Motion.snappy) {
                            changingPasscode = false
                            confirmingStop = false
                        }
                    }
                    .transition(.opacity)
            }
            if changingPasscode {
                PasscodeSheet {
                    withAnimation(Theme.Motion.snappy) { changingPasscode = false }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
            if confirmingStop {
                StopHubPanel(
                    onCancel: {
                        withAnimation(Theme.Motion.snappy) { confirmingStop = false }
                    },
                    onStop: {
                        withAnimation(Theme.Motion.snappy) { confirmingStop = false }
                        stopHub()
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
    }

    // Card container: same surface language as the stage's session cards
    // (black, 16pt radius, hairline rule).
    private func card(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s2) {
            Text(title).typo(.label).foregroundStyle(Theme.ink3)
                .padding(.leading, Theme.Space.s2)
            content()
        }
        .padding(Theme.Space.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bg)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .stroke(Theme.rule, lineWidth: 1)
        )
    }

    private var networkDetail: String {
        let host = Hub.baseURL.host() ?? ""
        guard !host.isEmpty else { return "HUB ADDRESS NOT SET" }
        if let ms = store.hubLatencyMs, store.hubOnline {
            return "HUB \(host) · \(ms) MS ROUND TRIP"
        }
        return store.hubOnline ? "HUB \(host)" : "HUB \(host) · UNREACHABLE"
    }

    private func flash(_ text: String, isError: Bool = false) {
        withAnimation(Theme.Motion.snappy) { notice = Notice(text: text, isError: isError) }
    }

    private func startHub() {
        hubBusy = true
        store.hubAdminInFlight = true
        flash("STARTING HUB")
        Task {
            // A keeper that answered with a failure is not an unreachable
            // keeper; the wrong message sends someone to the Mac for no reason.
            var keeperReached = true
            do { _ = try await Hub.keeperStart() }
            catch is Hub.Error { keeperReached = true }
            catch { keeperReached = false }
            var up = false
            for _ in 0..<10 {
                if await Hub.healthOK() { up = true; break }
                try? await Task.sleep(for: .seconds(1))
            }
            store.hubOnline = up
            store.hubAdminInFlight = false
            hubBusy = false
            flash(up ? "HUB ONLINE"
                     : keeperReached ? "HUB DID NOT START. CHECK THE MAC"
                                     : "KEEPER NOT ANSWERING. CHECK THE MAC",
                  isError: !up)
        }
    }

    private func restartHub() {
        hubBusy = true
        store.hubAdminInFlight = true
        flash("RESTARTING HUB")
        Task {
            try? await Hub.adminRestart()
            var back = false
            for _ in 0..<10 {
                try? await Task.sleep(for: .seconds(1))
                if await Hub.healthOK() { back = true; break }
            }
            store.hubOnline = back
            store.hubAdminInFlight = false
            hubBusy = false
            flash(back ? "HUB BACK ONLINE" : "HUB NOT ANSWERING. CHECK THE MAC",
                  isError: !back)
        }
    }

    private func stopHub() {
        hubBusy = true
        store.hubAdminInFlight = true
        flash("STOPPING HUB")
        Task {
            try? await Hub.adminStop()
            try? await Task.sleep(for: .seconds(1.5))
            let stillUp = await Hub.healthOK()
            store.hubOnline = stillUp
            store.hubAdminInFlight = false
            hubBusy = false
            flash(stillUp ? "HUB STILL RUNNING. TRY AGAIN"
                          : "HUB STOPPED. RESTART FROM THE MAC",
                  isError: !stillUp)
        }
    }

    private static let version =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    private static let build =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
}

// Wi-Fi quality from measured hub round-trip latency, bucketed into three
// bars. Lit bars use the live-state colour, as everywhere else.
private struct SignalBars: View {
    var latencyMs: Int?

    private var lit: Int {
        guard let ms = latencyMs else { return 0 }
        if ms < 60 { return 3 }
        if ms < 150 { return 2 }
        return 1
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(0..<3, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(i < lit ? Theme.signal : Theme.ink3.opacity(0.4))
                    .frame(width: 4, height: 6 + CGFloat(i) * 4)
            }
        }
        .accessibilityLabel(latencyMs == nil ? "No connection" : "Signal \(lit) of 3")
    }
}

// Change the signed-in profile's passcode: re-enter the current PIN, then the
// new one twice. The PIN is the identity, so the hub enforces uniqueness.
private struct PasscodeSheet: View {
    @Environment(AuthStore.self) private var auth
    var dismiss: () -> Void

    @State private var current = ""
    @State private var newPin = ""
    @State private var confirm = ""
    @State private var error: String?

    // Same panel as the session chooser: black pill, 1.5pt white border,
    // radius 28, × top-right cancels, white-bordered commit button.
    // Presented as an in-place overlay (no system sheet chrome).
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s3) {
            HStack {
                Spacer(minLength: 0)
                IconButton(systemName: "xmark", a11y: "Cancel") { dismiss() }
                    .padding(.trailing, -14)
            }
            Text("Change passcode").typo(.label).foregroundStyle(Theme.ink2)

            pinField("CURRENT PASSCODE", $current)
            pinField("NEW PASSCODE (4 DIGITS)", $newPin)
            pinField("CONFIRM NEW PASSCODE", $confirm)

            if let error {
                Text(error)
                    .font(.custom(FontStack.mono.medium, size: 10))
                    .tracking(0.1 * 10)
                    .foregroundStyle(Theme.alert)
            }

            Button(action: save) {
                HStack {
                    Text("Save passcode")
                        .font(.custom(FontStack.ui.semibold, size: 14))
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.right").font(.system(size: 14, weight: .semibold))
                }
                .foregroundStyle(Theme.grab)                  // white = the commit you grab
                .padding(.vertical, Theme.Space.s3)
                .padding(.horizontal, Theme.Space.s4)
                .frame(maxWidth: .infinity)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.sheet)
                        .stroke(Theme.grab, lineWidth: 1.5)
                )
            }
            .buttonStyle(.plain)
            .padding(.top, Theme.Space.s2)
        }
        .padding(20)
        .frame(minWidth: 380, maxWidth: 520, alignment: .leading)
        .background(Theme.bg)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.pill))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.pill)
                .stroke(Theme.grab, lineWidth: 1.5)          // white pill border
        )
    }

    private func pinField(_ label: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s1) {
            Text(label)
                .font(.custom(FontStack.mono.regular, size: 9.5))
                .tracking(0.12 * 9.5)
                .foregroundStyle(Theme.ink2)
            SecureField("", text: text)
                .keyboardType(.numberPad)
                .typo(.title).foregroundStyle(Theme.ink)
                .padding(Theme.Space.s3)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.key).fill(Theme.well))
        }
    }

    private func save() {
        guard newPin == confirm else { error = "NEW PASSCODES DON'T MATCH"; return }
        Task { @MainActor in
            // The hub owns the roster: the change stands only once its DB
            // says so (an unreachable hub would strand the next login).
            switch await auth.changePin(current: current, to: newPin) {
            case .success: dismiss()
            case .wrongCurrent: error = "CURRENT PASSCODE IS WRONG"
            case .notFourDigits: error = "PASSCODE MUST BE 4 DIGITS"
            case .inUse: error = "PASSCODE ALREADY IN USE"
            case .offline: error = "CAN'T REACH THE HUB. NOT CHANGED"
            }
        }
    }
}

// Stop-hub confirmation in the house style: same pill panel, plain words,
// white-bordered commit. Stopping is one-way from the iPad.
private struct StopHubPanel: View {
    var onCancel: () -> Void
    var onStop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s3) {
            HStack {
                Spacer(minLength: 0)
                IconButton(systemName: "xmark", a11y: "Cancel", action: onCancel)
                    .padding(.trailing, -14)
            }
            Text("Stop the hub?").typo(.label).foregroundStyle(Theme.ink2)

            Text("Music keeps playing on the speakers. Starting the hub again needs the Mac.")
                .font(.custom(FontStack.ui.regular, size: 13))
                .foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: onStop) {
                HStack {
                    Text("Stop hub")
                        .font(.custom(FontStack.ui.semibold, size: 14))
                    Spacer(minLength: 0)
                    Image(systemName: "power").font(.system(size: 14, weight: .semibold))
                }
                .foregroundStyle(Theme.alert)                // destructive commit
                .padding(.vertical, Theme.Space.s3)
                .padding(.horizontal, Theme.Space.s4)
                .frame(maxWidth: .infinity)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.sheet)
                        .stroke(Theme.alert, lineWidth: 1.5)
                )
            }
            .buttonStyle(.plain)
            .padding(.top, Theme.Space.s2)
        }
        .padding(20)
        .frame(minWidth: 380, maxWidth: 440, alignment: .leading)
        .background(Theme.bg)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.pill))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.pill)
                .stroke(Theme.grab, lineWidth: 1.5)          // white pill border
        )
    }
}
