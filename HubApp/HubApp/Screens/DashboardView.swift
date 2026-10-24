import SwiftUI

// Setup-and-maintenance panel. Everything here is a window onto the hub's own
// database and processes: the service (online, start/stop), the users (the
// same rows the iPad logs into: pick one, reset its PIN, lock it, remove
// it), the network name the household sees, room activity, and the logs the
// stack writes. Reads are free; actions unlock with an admin PIN.

struct DashboardView: View {
    var monitor: StackMonitor
    var installer: HubInstaller

    @State private var authName = ""
    @State private var authPin = ""
    @State private var confirmingUninstall = false
    @State private var uninstalling = false
    @State private var uninstallError: String?

    // Users card
    @State private var selectedUser = ""
    @State private var resetPinText = ""
    @State private var newName = ""
    @State private var newPin = ""
    @State private var addingUser = false
    @State private var userNote: Note?

    struct Note {
        let text: String
        var isError = false
        /// An action's return: nil = success note, else the hub's error.
        static func from(_ error: String?, success: String) -> Note {
            error.map { Note(text: $0, isError: true) } ?? Note(text: success)
        }
    }

    // Network card
    @State private var networkChoices: [String] = []
    @State private var networkText = ""
    @State private var networkNote: String?

    // Logs card
    @State private var logSource = "hub"
    @State private var logLines: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s5) {
            header
            ScrollView(showsIndicators: false) {
                VStack(spacing: Theme.Space.s5) {
                    HStack(alignment: .top, spacing: Theme.Space.s5) {
                        VStack(spacing: Theme.Space.s5) {
                            hubCard
                            usersCard
                        }
                        VStack(spacing: Theme.Space.s5) {
                            roomsCard
                            networkCard
                            spotifyCard
                        }
                    }
                    logsCard
                }
                .padding(.bottom, Theme.Space.s5)
            }
        }
        .padding(Theme.Space.s6 + 8)
        .onAppear { networkChoices = StackMonitor.preferredWifiNetworks() }
        .task(id: "\(logSource)-\(monitor.authedRole ?? "")") { await tailLogs() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Theme.Space.s3) {
            Image("ConsolLogo").resizable().scaledToFit().frame(width: 30)
            Text("CONSOL")
                .font(.custom("HelveticaNeue-Medium", size: 19))
                .tracking(0.6)
                .foregroundStyle(Theme.ink)
            Text("Hub")
                .font(.custom("HelveticaNeue", size: 19))
                .foregroundStyle(Theme.ink2)
            Spacer()
            StatusDot(color: monitor.hubUp ? Theme.online : Theme.alert)
            Text(monitor.hubUp ? "Hub online" : "Hub offline")
                .typo(.body)
                .foregroundStyle(monitor.hubUp ? Theme.ink : Theme.alert)
        }
    }

    // MARK: - Hub

    private var hubCard: some View {
        Card(title: "Hub") {
            row("Hub service", monitor.hubUp ? "Online" : "Offline", ok: monitor.hubUp)
            row("Keeper", monitor.keeperUp ? "Online" : "Offline", ok: monitor.keeperUp)
            row("Round trip", monitor.latencyMS.map { "\($0) ms" } ?? "—", ok: monitor.hubUp)
            divider
            if monitor.token == nil {
                if monitor.hubUp {
                    HStack(alignment: .bottom, spacing: Theme.Space.s3) {
                        WellField(label: "Name", text: $authName)
                        WellField(label: "PIN", text: $authPin, secure: true)
                        PillButton(label: "Unlock", style: .grab) {
                            Task {
                                if await monitor.login(name: authName, pin: authPin) {
                                    authPin = ""
                                }
                            }
                        }
                    }
                    Text("Start, stop, and every change below unlock with a household PIN.")
                        .typo(.caption).foregroundStyle(Theme.ink3)
                } else {
                    // Nothing answers and nothing can sign in: the way out
                    // is the keeper, or the wizard.
                    HStack(spacing: Theme.Space.s3) {
                        PillButton(label: "Start", style: .grab, disabled: monitor.busy) {
                            Task { await monitor.startHub() }
                        }
                        PillButton(label: "Reinstall…") {
                            monitor.enterSetup()
                        }
                    }
                    Text("Start kicks the keeper through launchd. Reinstall runs setup again and keeps the existing database and Spotify link.")
                        .typo(.caption).foregroundStyle(Theme.ink3)
                }
            } else {
                HStack(spacing: Theme.Space.s3) {
                    PillButton(label: "Start", disabled: monitor.hubUp || monitor.busy) {
                        Task { await monitor.startHub() }
                    }
                    PillButton(label: "Restart", disabled: !monitor.hubUp || monitor.busy) {
                        Task { await monitor.restartHub() }
                    }
                    PillButton(label: "Stop", style: .danger,
                               disabled: !monitor.hubUp || monitor.busy) {
                        Task { await monitor.stopHub() }
                    }
                    Spacer()
                    Text("Signed in as \(monitor.authedName ?? "")")
                        .typo(.caption).foregroundStyle(Theme.ink3)
                }
                if monitor.authedRole == "admin" {
                    uninstallZone
                }
            }
            if let error = monitor.lastActionError {
                Text(error).typo(.caption).foregroundStyle(Theme.alert)
            }
        }
    }

    @ViewBuilder private var uninstallZone: some View {
        divider
        if uninstalling {
            Text("Uninstalling…").typo(.caption).foregroundStyle(Theme.ink2)
        } else if confirmingUninstall {
            Text(FileManager.default.fileExists(atPath: HubInstaller.installDir.path)
                 ? "This stops the hub, takes it out of launchd, and deletes the install, including users, the Spotify link and saved speakers. Setup runs again from the start."
                 : "This stops the hub and takes it out of launchd. The development checkout's files stay where they are.")
                .typo(.caption).foregroundStyle(Theme.ink2)
            HStack(spacing: Theme.Space.s3) {
                PillButton(label: "Uninstall the hub", style: .danger) {
                    Task {
                        uninstalling = true
                        uninstallError = await installer.uninstall(token: monitor.token)
                        uninstalling = false
                        if uninstallError == nil {
                            confirmingUninstall = false
                            monitor.enterSetup()
                        }
                    }
                }
                PillButton(label: "Cancel") { confirmingUninstall = false }
            }
        } else {
            PillButton(label: "Uninstall…", style: .danger) {
                confirmingUninstall = true
                uninstallError = nil
            }
        }
        if let uninstallError {
            Text(uninstallError).typo(.caption).foregroundStyle(Theme.alert)
        }
    }

    // MARK: - Users

    private var selected: StackMonitor.HubUser? {
        monitor.users.first { $0.name == selectedUser }
    }

    private var usersCard: some View {
        Card(title: "Users") {
            if monitor.token == nil {
                Text("Unlock above to manage the household database.")
                    .typo(.caption).foregroundStyle(Theme.ink3)
            } else if monitor.authedRole != "admin" {
                ForEach(monitor.users) { user in
                    userRow(user)
                }
            } else {
                Menu {
                    ForEach(monitor.users) { user in
                        Button(user.name + (user.locked ? "  (locked)" : "")) {
                            selectedUser = user.name
                            userNote = nil
                        }
                    }
                } label: {
                    HStack {
                        Text(selectedUser.isEmpty ? "Choose a user" : selectedUser)
                            .typo(.body).foregroundStyle(Theme.ink)
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.ink2)
                    }
                    .padding(.horizontal, Theme.Space.s3)
                    .padding(.vertical, Theme.Space.s3 - 2)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .frame(maxWidth: 260)

                if let user = selected {
                    HStack(spacing: Theme.Space.s2) {
                        Text(user.role == "admin" ? "Admin" : "Member")
                            .typo(.caption).foregroundStyle(Theme.ink2)
                        if user.locked {
                            Text("· Locked").typo(.caption).foregroundStyle(Theme.alert)
                        }
                        if user.name == monitor.authedName {
                            Text("· You").typo(.caption).foregroundStyle(Theme.ink3)
                        }
                    }
                    HStack(alignment: .bottom, spacing: Theme.Space.s3) {
                        WellField(label: "New PIN", text: $resetPinText, secure: true)
                            .frame(width: 120)
                        PillButton(label: "Reset PIN") {
                            Task {
                                let error = await monitor.resetPin(name: user.name, pin: resetPinText)
                                if error == nil { resetPinText = "" }
                                userNote = .from(error, success: "PIN reset for \(user.name).")
                            }
                        }
                        Spacer()
                    }
                    HStack(spacing: Theme.Space.s3) {
                        PillButton(label: user.locked ? "Unlock" : "Lock",
                                   disabled: user.name == monitor.authedName) {
                            Task {
                                let error = await monitor.setLocked(name: user.name, locked: !user.locked)
                                userNote = .from(error, success: user.locked
                                                 ? "\(user.name) unlocked." : "\(user.name) locked.")
                            }
                        }
                        PillButton(label: "Remove", style: .danger,
                                   disabled: user.name == monitor.authedName) {
                            Task {
                                let error = await monitor.removeUser(name: user.name)
                                if error == nil { selectedUser = monitor.users.first?.name ?? "" }
                                userNote = .from(error, success: "\(user.name) removed.")
                            }
                        }
                        Spacer()
                    }
                }
                divider
                if addingUser {
                    HStack(alignment: .bottom, spacing: Theme.Space.s3) {
                        WellField(label: "Name", text: $newName)
                        WellField(label: "PIN", text: $newPin, secure: true)
                        PillButton(label: "Add", style: .grab) {
                            Task {
                                let error = await monitor.addUser(name: newName, pin: newPin)
                                userNote = .from(error, success: "\(newName) added.")
                                if error == nil {
                                    selectedUser = newName
                                    newName = ""; newPin = ""; addingUser = false
                                }
                            }
                        }
                        PillButton(label: "Cancel") { addingUser = false }
                    }
                } else {
                    PillButton(label: "Add user") { addingUser = true; userNote = nil }
                }
                Text("This is the same database the iPad signs into, so changes apply immediately without an app update. Locking a user refuses their PIN and ends their session.")
                    .typo(.caption).foregroundStyle(Theme.ink3)
                if let userNote {
                    Text(userNote.text).typo(.caption)
                        .foregroundStyle(userNote.isError ? Theme.alert : Theme.ink2)
                }
            }
        }
        .onChange(of: monitor.users) {
            if selected == nil { selectedUser = monitor.users.first?.name ?? "" }
        }
    }

    private func userRow(_ user: StackMonitor.HubUser) -> some View {
        HStack(spacing: Theme.Space.s3) {
            Text(user.name).typo(.body).foregroundStyle(Theme.ink)
            Text(user.role == "admin" ? "Admin" : "Member")
                .typo(.caption).foregroundStyle(Theme.ink3)
            if user.locked { Text("Locked").typo(.caption).foregroundStyle(Theme.alert) }
            Spacer()
        }
    }

    // MARK: - Rooms

    private var roomsCard: some View {
        Card(title: "Rooms") {
            if monitor.rooms.isEmpty {
                Text(monitor.hubUp ? "No Sonos speakers reachable." : "—")
                    .typo(.caption).foregroundStyle(Theme.ink3)
            } else {
                ForEach(monitor.rooms) { room in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(room.name).typo(.body).foregroundStyle(Theme.ink)
                            Spacer()
                            StatusDot(color: Theme.online)
                            Text(room.playing ? "Playing" : "Online")
                                .typo(.value).foregroundStyle(Theme.ink)
                        }
                        if let nowPlaying = room.nowPlaying {
                            Text(nowPlaying).typo(.caption).foregroundStyle(Theme.ink2)
                                .lineLimit(1)
                        }
                    }
                }
                Text("A room listed here answered on the network just now.")
                    .typo(.caption).foregroundStyle(Theme.ink3)
            }
        }
    }

    // MARK: - Network

    private var networkCard: some View {
        Card(title: "Network") {
            row("Household sees", monitor.networkName ?? "—", ok: true)
            if monitor.token != nil && monitor.authedRole == "admin" {
                HStack(alignment: .bottom, spacing: Theme.Space.s3) {
                    VStack(alignment: .leading, spacing: Theme.Space.s2) {
                        SectionLabel("Network name")
                        HStack(spacing: Theme.Space.s2) {
                            TextField("", text: $networkText)
                                .textFieldStyle(.plain)
                                .typo(.body)
                                .foregroundStyle(Theme.ink)
                                .padding(.horizontal, Theme.Space.s3)
                                .padding(.vertical, Theme.Space.s3 - 2)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
                                .overlay(RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
                            if !networkChoices.isEmpty {
                                Menu {
                                    ForEach(networkChoices, id: \.self) { choice in
                                        Button(choice) { networkText = choice }
                                    }
                                } label: {
                                    Image(systemName: "chevron.down")
                                        .foregroundStyle(Theme.ink2)
                                }
                                .menuStyle(.borderlessButton)
                                .menuIndicator(.hidden)
                                .frame(width: 24)
                            }
                        }
                    }
                    PillButton(label: "Set", style: .grab) {
                        Task {
                            networkNote = await monitor.setNetwork(networkText)
                            if networkNote == nil { networkNote = "Saved." }
                        }
                    }
                }
                Text("The dropdown lists Wi-Fi networks this Mac remembers. The name shows on the iPad's profile page.")
                    .typo(.caption).foregroundStyle(Theme.ink3)
                if let networkNote {
                    Text(networkNote).typo(.caption)
                        .foregroundStyle(networkNote == "Saved." ? Theme.ink2 : Theme.alert)
                }
            }
        }
    }

    // MARK: - Spotify

    private var spotifyCard: some View {
        Card(title: "Spotify") {
            row("Credentials", monitor.spotifyConfigured ? "In place" : "Missing",
                ok: monitor.spotifyConfigured)
            row("Account", monitor.spotifyConnected ? "Linked" : "Not linked",
                ok: monitor.spotifyConnected)
            if monitor.hubUp && !monitor.spotifyConnected {
                PillButton(label: "Link Spotify", style: .grab) {
                    NSWorkspace.shared.open(
                        StackMonitor.hubBase.appendingPathComponent("spotify/auth"))
                }
            }
        }
    }

    // MARK: - Logs

    private var logsCard: some View {
        Card(title: "Logs") {
            if monitor.token == nil || monitor.authedRole != "admin" {
                Text("Unlock with an admin PIN to read what the stack writes.")
                    .typo(.caption).foregroundStyle(Theme.ink3)
            } else {
                Picker("", selection: $logSource) {
                    Text("Hub").tag("hub")
                    Text("Keeper").tag("keeper")
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            if logLines.isEmpty {
                                Text("Nothing logged yet.")
                                    .typo(.caption).foregroundStyle(Theme.ink3)
                            }
                            ForEach(Array(logLines.enumerated()), id: \.offset) { i, line in
                                Text(line)
                                    .typo(.console)
                                    .foregroundStyle(Theme.ink2)
                                    .textSelection(.enabled)
                                    .id(i)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Theme.Space.s3)
                    }
                    .frame(height: 200)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
                    .onChange(of: logLines.count) {
                        if let last = logLines.indices.last {
                            proxy.scrollTo(last, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    private func tailLogs() async {
        while !Task.isCancelled {
            if monitor.token != nil && monitor.authedRole == "admin" {
                logLines = await monitor.fetchLogs(source: logSource)
            }
            try? await Task.sleep(for: .seconds(4))
        }
    }

    // MARK: - Shared bits

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.18)).frame(height: 1)
            .padding(.vertical, Theme.Space.s1)
    }

    private func row(_ label: String, _ value: String, ok: Bool) -> some View {
        HStack {
            Text(label).typo(.body).foregroundStyle(Theme.ink2)
            Spacer()
            Text(value)
                .typo(.value)
                .foregroundStyle(ok ? Theme.ink : Theme.alert)
        }
    }
}
