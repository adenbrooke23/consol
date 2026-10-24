import SwiftUI

// Devices tab: every output, its status, and the session that owns it.
// Speakers are the live Sonos rooms (store.outputs); Apple TVs come from the
// hub's /tv/devices. A paired TV gets real controls (power, app launch, and
// remote keys), all through the hub; the iPad never talks to the TV.

struct DevicesScreen: View {
    @Environment(SessionStore.self) private var store

    @State private var tvs: [Hub.TVDevice] = []
    @State private var tvStatuses: [String: Hub.TVStatus] = [:]
    @State private var scanned = false
    @State private var notice: Notice?

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            ScrollView {
                VStack(spacing: Theme.Space.s4) {
                    Spacer(minLength: Theme.Space.s4)
                    Text("Devices")
                        .typo(.display).foregroundStyle(Theme.ink)
                        .padding(.bottom, Theme.Space.s2)

                    card("SPEAKERS") {
                        if store.outputs.filter({ $0.kind == .speaker }).isEmpty {
                            Text(store.hubOnline ? "No speakers found" : "Hub offline")
                                .font(.custom(FontStack.ui.regular, size: 13))
                                .foregroundStyle(Theme.ink2)
                                .padding(Theme.Space.s3)
                        }
                        ForEach(store.outputs.filter { $0.kind == .speaker }) { output in
                            speakerRow(output)
                        }
                    }

                    card("APPLE TVS") {
                        if !scanned {
                            Text("Looking for Apple TVs…")
                                .font(.custom(FontStack.ui.regular, size: 13))
                                .foregroundStyle(Theme.ink2)
                                .padding(Theme.Space.s3)
                        } else if tvs.isEmpty {
                            Text("No Apple TVs found")
                                .font(.custom(FontStack.ui.regular, size: 13))
                                .foregroundStyle(Theme.ink2)
                                .padding(Theme.Space.s3)
                        }
                        ForEach(tvs) { tv in
                            TVSection(tv: tv, status: tvStatuses[tv.identifier],
                                      flash: flash) {
                                await refreshStatus(tv)
                            }
                        }
                    }

                    Spacer(minLength: Theme.Space.s6)
                }
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
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
            guard notice != nil else { return }
            try? await Task.sleep(for: .seconds(2.4))
            withAnimation(Theme.Motion.snappy) { notice = nil }
        }
        // One LAN scan per visit (the hub's scan takes ~8s), then a light
        // status poll for the paired TVs while the tab is on screen.
        .task {
            if let found = try? await Hub.tvDevices() {
                tvs = found
            }
            scanned = true
            while !Task.isCancelled {
                for tv in tvs where tv.paired && !tv.isProtected {
                    await refreshStatus(tv)
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func refreshStatus(_ tv: Hub.TVDevice) async {
        if let status = try? await Hub.tvStatus(tv.identifier) {
            tvStatuses[tv.identifier] = status
        }
    }

    private func speakerRow(_ output: Output) -> some View {
        let owner = store.owner(of: output)
        return HStack(spacing: Theme.Space.s3) {
            Image(systemName: "hifispeaker")
                .font(.system(size: 16))
                .foregroundStyle(Theme.ink2)
                .frame(width: 28)
            Text(output.name)
                .font(.custom(FontStack.ui.medium, size: 14))
                .foregroundStyle(Theme.ink)
            Spacer(minLength: 0)
            Text(owner.map { $0.title.uppercased() } ?? "FREE")
                .font(.custom(FontStack.mono.regular, size: 9.5))
                .tracking(0.1 * 9.5)
                .foregroundStyle(owner != nil ? Theme.signal : Theme.ink3)
                .lineLimit(1)
        }
        .padding(Theme.Space.s3)
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.key)
            .stroke(Theme.rule, lineWidth: 1))
    }

    private func flash(_ text: String, isError: Bool) {
        withAnimation(Theme.Motion.snappy) { notice = Notice(text: text, isError: isError) }
    }

    // Card container: same surface language as Profile's cards.
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
}

// One Apple TV inside the APPLE TVS card: status line, then (paired only)
// power, an app launcher, and a remote pad. Unpaired TVs are listed but
// inert; pairing is an admin job on the Mac, not here.
private struct TVSection: View {
    let tv: Hub.TVDevice
    let status: Hub.TVStatus?
    var flash: (String, Bool) -> Void
    var refresh: () async -> Void

    @State private var showApps = false
    @State private var apps: [Hub.TVApp] = []
    @State private var showRemote = false
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s2) {
            HStack(spacing: 6) {
                Image(systemName: "appletv")
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.ink2)
                    .frame(width: 28)
                Text(tv.name)
                    .font(.custom(FontStack.ui.medium, size: 14))
                    .foregroundStyle(Theme.ink)
                Spacer(minLength: 0)
                if tv.isProtected {
                    // A protected Apple TV: listed so it's accounted for,
                    // never controllable. The hub refuses it too.
                    Text("PROTECTED")
                        .font(.custom(FontStack.mono.regular, size: 9.5))
                        .tracking(0.1 * 9.5)
                        .foregroundStyle(Theme.ink3)
                } else if tv.paired {
                    Circle()
                        .fill(status?.isOn == true ? Theme.signal : Theme.ink3.opacity(0.4))
                        .frame(width: 6, height: 6)
                    Text(statusLabel)
                        .font(.custom(FontStack.mono.regular, size: 9.5))
                        .tracking(0.1 * 9.5)
                        .foregroundStyle(Theme.ink3)
                        .lineLimit(1)
                } else {
                    Text("NOT PAIRED")
                        .font(.custom(FontStack.mono.regular, size: 9.5))
                        .tracking(0.1 * 9.5)
                        .foregroundStyle(Theme.ink3)
                }
            }
            .padding(Theme.Space.s3)

            if tv.paired && !tv.isProtected {
                OptionRow(icon: "power",
                          label: status?.isOn == true ? "Turn off" : "Turn on",
                          trailing: busy ? "WORKING" : nil,
                          trailingColor: Theme.signal, selected: false) {
                    togglePower()
                }
                OptionRow(icon: "square.grid.3x3",
                          label: "Open app",
                          trailing: nil, trailingColor: Theme.ink3,
                          selected: showApps) {
                    withAnimation(Theme.Motion.snappy) { showApps.toggle() }
                    if showApps && apps.isEmpty { loadApps() }
                }
                if showApps {
                    appGrid
                }
                OptionRow(icon: "dpad",
                          label: "Remote",
                          trailing: nil, trailingColor: Theme.ink3,
                          selected: showRemote) {
                    withAnimation(Theme.Motion.snappy) { showRemote.toggle() }
                }
                if showRemote {
                    TVRemotePad { key in press(key) }
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.key)
            .stroke(Theme.rule, lineWidth: 1))
    }

    private var statusLabel: String {
        guard let status else { return "…" }
        if !status.isOn { return "OFF" }
        if let title = status.title, !title.isEmpty { return title.uppercased() }
        if let app = status.app { return "ON · \(app.uppercased())" }
        return "ON"
    }

    private func togglePower() {
        guard !busy else { return }
        busy = true
        let turningOn = !(status?.isOn == true)
        Task {
            do {
                try await Hub.tvPower(tv.identifier, on: turningOn)
                flash(turningOn ? "TV ON" : "TV OFF", false)
                await refresh()
            } catch {
                flash(error.localizedDescription.uppercased(), true)
            }
            busy = false
        }
    }

    private func loadApps() {
        Task {
            do { apps = try await Hub.tvApps(tv.identifier) }
            catch { flash(error.localizedDescription.uppercased(), true) }
        }
    }

    private func press(_ key: String) {
        Task {
            do { try await Hub.tvKey(tv.identifier, key) }
            catch { flash(error.localizedDescription.uppercased(), true) }
        }
    }

    private var appGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: Theme.Space.s2)],
                  spacing: Theme.Space.s2) {
            ForEach(apps) { app in
                Button {
                    Task {
                        do {
                            try await Hub.tvLaunch(tv.identifier, app: app.id)
                            flash("OPENING \(app.name.uppercased())", false)
                            await refresh()
                        } catch {
                            flash(error.localizedDescription.uppercased(), true)
                        }
                    }
                } label: {
                    Text(app.name)
                        .font(.custom(FontStack.ui.medium, size: 12.5))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                        .padding(.vertical, Theme.Space.s2)
                        .padding(.horizontal, Theme.Space.s3)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.key)
                            .stroke(Theme.rule, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(Theme.Space.s3)
    }
}

#Preview {
    DevicesScreen()
        .environment(SessionStore(sessions: MockData.sessions))
        .environment(AuthStore())
}
