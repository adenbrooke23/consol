import SwiftUI

// The installer: a left rail of steps, one card of questions at a time, then
// a live console while the real work runs. Same rules as the dashboard:
// black cards, white borders, native type, sentence case, no system chrome.

struct WizardView: View {
    enum Page: Int, CaseIterable {
        case welcome, spotify, household, network, install, done

        var railTitle: String {
            switch self {
            case .welcome: return "Welcome"
            case .spotify: return "Spotify"
            case .household: return "Household"
            case .network: return "Network"
            case .install: return "Install"
            case .done: return "Done"
            }
        }
    }

    @Bindable var installer: HubInstaller
    var monitor: StackMonitor

    @State private var page: Page = .welcome
    @State private var form = SetupForm()
    @State private var validationNote: String?

    var body: some View {
        HStack(spacing: 0) {
            rail
            Rectangle().fill(Color.white.opacity(0.18)).frame(width: 1)
            content
        }
    }

    // MARK: - Rail

    private var rail: some View {
        VStack(alignment: .leading, spacing: 0) {
            Wordmark(compact: true)
                .frame(maxWidth: .infinity)
                .padding(.top, Theme.Space.s7)
            Text("Hub installer")
                .typo(.caption).foregroundStyle(Theme.ink2)
                .frame(maxWidth: .infinity)
                .padding(.top, Theme.Space.s2)
            VStack(alignment: .leading, spacing: Theme.Space.s4) {
                ForEach(Page.allCases, id: \.rawValue) { p in
                    HStack(spacing: Theme.Space.s3) {
                        StatusDot(color: p == page ? Theme.signal
                                  : (p.rawValue < page.rawValue ? Theme.ink : Theme.ink3))
                        Text(p.railTitle)
                            .typo(.body)
                            .foregroundStyle(p == page ? Theme.ink : Theme.ink2)
                    }
                }
            }
            .padding(.top, Theme.Space.s7)
            .padding(.leading, Theme.Space.s6)
            Spacer()
        }
        .frame(width: 230)
    }

    // MARK: - Pages

    private var content: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s5) {
            Group {
                switch page {
                case .welcome: welcomePage
                case .spotify: spotifyPage
                case .household: householdPage
                case .network: networkPage
                case .install: installPage
                case .done: donePage
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            footer
        }
        .padding(Theme.Space.s7)
    }

    private var welcomePage: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s5) {
            Text("This Mac becomes the brain.")
                .typo(.display).foregroundStyle(Theme.ink)
            Text("Consol runs the whole house from one always-on Mac: Sonos speakers, Spotify, Apple TVs. This installer copies the hub service onto this Mac, keeps it alive across reboots, and the Consol app on your iPad does the rest.")
                .typo(.body).foregroundStyle(Theme.ink2)
                .frame(maxWidth: 520, alignment: .leading)
            Text("Takes a few minutes. You will need your Spotify developer credentials.")
                .typo(.caption).foregroundStyle(Theme.ink3)
        }
    }

    private var spotifyPage: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s5) {
            Text("Spotify credentials").typo(.display).foregroundStyle(Theme.ink)
            Card {
                WellField(label: "Client ID", text: $form.spotifyClientID)
                WellField(label: "Client secret", text: $form.spotifyClientSecret, secure: true)
                Text("Create an app at developer.spotify.com with the redirect URI http://127.0.0.1:8000/spotify/callback and Web API access. Leave blank to link Spotify later from the dashboard.")
                    .typo(.caption).foregroundStyle(Theme.ink3)
            }
            .frame(maxWidth: 520)
        }
    }

    private var householdPage: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s5) {
            Text("Who lives here").typo(.display).foregroundStyle(Theme.ink)
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.s4) {
                    Card(title: "Admin") {
                        HStack(spacing: Theme.Space.s4) {
                            WellField(label: "Name", text: $form.adminName)
                            WellField(label: "PIN (4 digits)", text: $form.adminPin, secure: true)
                        }
                        Text("The admin PIN unlocks everything, on the iPad and here.")
                            .typo(.caption).foregroundStyle(Theme.ink3)
                    }
                    Card(title: "Members") {
                        ForEach($form.members) { $member in
                            HStack(spacing: Theme.Space.s4) {
                                WellField(label: "Name", text: $member.name)
                                WellField(label: "PIN", text: $member.pin, secure: true)
                                PillButton(label: "Remove", style: .danger) {
                                    form.members.removeAll { $0.id == member.id }
                                }
                            }
                        }
                        PillButton(label: "Add member") {
                            form.members.append(MemberDraft())
                        }
                        Text("Every PIN must be unique. The PIN is how the house knows who you are.")
                            .typo(.caption).foregroundStyle(Theme.ink3)
                    }
                }
                .frame(maxWidth: 620, alignment: .leading)
            }
        }
    }

    private var networkPage: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s5) {
            Text("Your network").typo(.display).foregroundStyle(Theme.ink)
            Card {
                WellField(label: "Wi-Fi network name (optional)", text: $form.networkName,
                          hint: "Shown on the iPad's Profile page. macOS hides the network name from apps, so tell the hub what to call it.")
            }
            .frame(maxWidth: 520)
            Text("This Mac must be on the same network as your Sonos speakers.")
                .typo(.caption).foregroundStyle(Theme.ink3)
        }
    }

    private var installPage: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s5) {
            Text(installer.failed ? "Install hit a wall." : "Installing.")
                .typo(.display).foregroundStyle(installer.failed ? Theme.alert : Theme.ink)
            HStack(alignment: .top, spacing: Theme.Space.s5) {
                VStack(alignment: .leading, spacing: Theme.Space.s4) {
                    ForEach(installer.steps) { step in
                        HStack(spacing: Theme.Space.s3) {
                            StatusDot(color: dotColor(step.state))
                            Text(step.title)
                                .typo(.body)
                                .foregroundStyle(step.state == .pending ? Theme.ink3 : Theme.ink)
                        }
                    }
                }
                .frame(width: 250, alignment: .leading)
                console
            }
        }
    }

    private func dotColor(_ state: HubInstaller.StepState) -> Color {
        switch state {
        case .pending: return Theme.ink3
        case .running: return Theme.signal
        case .done: return Theme.ink
        case .failed: return Theme.alert
        }
    }

    private var console: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(installer.logLines.enumerated()), id: \.offset) { i, line in
                        Text(line)
                            .typo(.console)
                            .foregroundStyle(line.hasPrefix("$") ? Theme.ink3 : Theme.ink2)
                            .textSelection(.enabled)
                            .id(i)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Space.s4)
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
            .onChange(of: installer.logLines.count) {
                if let last = installer.logLines.indices.last {
                    proxy.scrollTo(last, anchor: .bottom)
                }
            }
        }
    }

    private var donePage: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s5) {
            HStack(spacing: Theme.Space.s3) {
                StatusDot(color: Theme.online)
                Text("The hub is online.").typo(.display).foregroundStyle(Theme.ink)
            }
            Text("It now runs on its own, survives reboots, and the iPad can wake it. Open Consol on the iPad and sign in with your PIN.")
                .typo(.body).foregroundStyle(Theme.ink2)
                .frame(maxWidth: 520, alignment: .leading)
            if !form.spotifyClientID.isEmpty {
                Text("One thing left: link the household Spotify account.")
                    .typo(.body).foregroundStyle(Theme.ink2)
                PillButton(label: "Link Spotify", style: .grab) {
                    NSWorkspace.shared.open(
                        StackMonitor.hubBase.appendingPathComponent("spotify/auth"))
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if page != .welcome && page.rawValue < Page.install.rawValue {
                PillButton(label: "Back") {
                    validationNote = nil
                    page = Page(rawValue: page.rawValue - 1) ?? .welcome
                }
            }
            if let validationNote {
                Text(validationNote).typo(.caption).foregroundStyle(Theme.alert)
                    .padding(.leading, Theme.Space.s4)
            }
            Spacer()
            switch page {
            case .welcome, .spotify, .network:
                PillButton(label: page == .network ? "Install" : "Continue", style: .grab) {
                    advance()
                }
            case .household:
                PillButton(label: "Continue", style: .grab) { advance() }
            case .install:
                if installer.failed {
                    PillButton(label: "Try again", style: .grab) {
                        Task { await runInstall() }
                    }
                }
            case .done:
                PillButton(label: "Open dashboard", style: .grab) {
                    monitor.enterDashboard()
                }
            }
        }
    }

    private func advance() {
        validationNote = nil
        if page == .household, let problem = householdProblem() {
            validationNote = problem
            return
        }
        if page == .network {
            page = .install
            Task { await runInstall() }
            return
        }
        page = Page(rawValue: page.rawValue + 1) ?? .done
    }

    private func householdProblem() -> String? {
        func pinOK(_ pin: String) -> Bool { pin.count == 4 && pin.allSatisfy(\.isNumber) }
        guard !form.adminName.trimmingCharacters(in: .whitespaces).isEmpty else {
            return "The admin needs a name."
        }
        guard pinOK(form.adminPin) else { return "The admin PIN must be 4 digits." }
        var pins = [form.adminPin]
        for member in form.members {
            guard !member.name.trimmingCharacters(in: .whitespaces).isEmpty else {
                return "Every member needs a name."
            }
            guard pinOK(member.pin) else { return "\(member.name)'s PIN must be 4 digits." }
            pins.append(member.pin)
        }
        guard Set(pins).count == pins.count else {
            return "PINs must be unique. The PIN is how the house knows who you are."
        }
        return nil
    }

    private func runInstall() async {
        await installer.install(form)
        if installer.finished {
            await monitor.refresh()
            page = .done
        }
    }
}
