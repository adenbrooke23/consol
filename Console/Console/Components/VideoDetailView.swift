import SwiftUI

// The video (Live TV / Film / Apps) card's in-place detail body. A channel or
// episode picker, a subtitle/audio toggle, and a Remote row that opens the
// companion remote card (RemoteCardView) beside this one.
// Video kinds carry no Spotify features.

struct VideoDetailView: View {
    @Binding var session: Session
    @Environment(SessionStore.self) private var store

    @State private var apps: [Hub.TVApp] = []
    @State private var appQuery = ""

    private var id: Session.ID { session.id }

    private var filteredApps: [Hub.TVApp] {
        let q = appQuery.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return apps }
        return apps.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    // Pinned header + the Remote row (opens the companion remote card, the
    // way search opens browse), then the channel/episode/app picker in a
    // plain ScrollView, because List hit-testing is unreliable inside cards.
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s3) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title).typo(.cardTitle).foregroundStyle(Theme.ink).lineLimit(1)
                Text(session.subtitle)
                    .font(.custom(FontStack.ui.regular, size: 12.5))
                    .foregroundStyle(Theme.ink2).lineLimit(1)
            }
            togglesRow
            OptionRow(icon: "dpad", label: "Remote",
                      trailing: nil, trailingColor: Theme.ink3,
                      selected: store.remoteFor == id) {
                withAnimation(Theme.Motion.snappy) {
                    store.remoteFor = (store.remoteFor == id) ? nil : id
                }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Space.s1) {
                    pickerSection
                }
            }
            .scrollIndicators(.hidden)
        }
        .task {
            guard session.kind == .apps, apps.isEmpty,
                  let room = session.deviceNames.first else { return }
            apps = (try? await Hub.tvApps(room)) ?? []
        }
    }

    private var togglesRow: some View {
        HStack(spacing: Theme.Space.s2) {
            GlyphToggle(onName: "captions.bubble.fill", offName: "captions.bubble",
                        isOn: session.subtitlesOn, a11y: "Subtitles") { store.toggleSubtitles(id) }
            Text("Subtitles").font(.custom(FontStack.ui.regular, size: 13))
                .foregroundStyle(session.subtitlesOn ? Theme.ink : Theme.ink2)
            Spacer(minLength: 0)
            GlyphToggle(onName: "waveform", isOn: false, a11y: "Audio track") {}
            Text("Audio").font(.custom(FontStack.ui.regular, size: 13)).foregroundStyle(Theme.ink2)
        }
    }

    @ViewBuilder private var pickerSection: some View {
        switch session.kind {
        case .liveTV:
            header("CHANNELS")
            ForEach(MockData.channels, id: \.self) { ch in
                pickRow(ch, current: session.subtitle.hasPrefix(ch)) {
                    session.subtitle = "\(ch) · LIVE"
                }
            }
        case .film:
            header("EPISODES")
            ForEach(MockData.episodes, id: \.0) { ep in
                pickRow(ep.0, trailing: ep.1, current: session.title == ep.0) {
                    session.title = ep.0
                }
            }
        case .apps:
            // The TV's real installed apps (hub-fetched); tap = launch there.
            header("APPS")
            appSearchField
            ForEach(filteredApps) { app in
                pickRow(app.name, current: session.title == app.name) {
                    store.launchTVApp(id, app)
                }
            }
        case .music:
            EmptyView()
        }
    }

    // Filter the (long) app list as you type.
    private var appSearchField: some View {
        HStack(spacing: Theme.Space.s2) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(Theme.ink3)
            TextField("", text: $appQuery,
                      prompt: Text("Find an app").foregroundStyle(Theme.ink3))
                .font(.custom(FontStack.ui.regular, size: 14))
                .foregroundStyle(Theme.ink)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !appQuery.isEmpty {
                Button { appQuery = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.ink3)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(Theme.Space.s2)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.key).fill(Theme.well))
        .padding(.bottom, Theme.Space.s1)
    }

    private func pickRow(_ label: String, trailing: String? = nil, current: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.s3) {
                Text(label).font(.custom(FontStack.ui.medium, size: 14))
                    .foregroundStyle(current ? Theme.ink : Theme.ink2)
                Spacer(minLength: 0)
                if let trailing {
                    Text(trailing).typo(.readoutS).foregroundStyle(Theme.ink3)
                }
                if current {
                    Circle().fill(Theme.signal).frame(width: 5, height: 5)   // live selection dot
                }
            }
            .padding(.vertical, Theme.Space.s2).padding(.horizontal, Theme.Space.s3)
            .contentShape(Rectangle())
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.key)
                .stroke(current ? Theme.ink2 : Theme.rule, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func header(_ text: String) -> some View {
        Text(text).typo(.label).foregroundStyle(Theme.ink3)
            .padding(.top, Theme.Space.s3).padding(.bottom, Theme.Space.s1)
    }
}
