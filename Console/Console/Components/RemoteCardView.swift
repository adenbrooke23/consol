import SwiftUI

// The companion remote card. Opens beside the focused video card (browse-card
// pattern: same true-black fill, 14pt radius, white active edge) and drives
// the session's TV through the hub. × closes; focusing another card closes it
// too (store-enforced, same contract as browse).

struct RemoteCardView: View {
    let session: Session
    @Environment(SessionStore.self) private var store

    @State private var typed = ""
    @State private var lastSent = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s3) {
            HStack(spacing: Theme.Space.s2) {
                Text("REMOTE · \(session.whereLabel.uppercased())")
                    .typo(.label).foregroundStyle(Theme.ink2)
                Spacer(minLength: 0)
                IconButton(systemName: "xmark", a11y: "Close remote") {
                    withAnimation(Theme.Motion.snappy) { store.remoteFor = nil }
                }
                .padding(.trailing, -14)
            }

            // Type-on-TV: whatever lands here streams into the TV's focused
            // text field (an app's search box) as you type. Needs a field
            // focused on screen; the hub answers 409 otherwise.
            HStack(spacing: Theme.Space.s2) {
                Image(systemName: "keyboard")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.ink2)
                TextField("", text: $typed,
                          prompt: Text("Type on TV").foregroundStyle(Theme.ink3))
                    .font(.custom(FontStack.ui.regular, size: 14))
                    .foregroundStyle(Theme.ink)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                if !typed.isEmpty {
                    Button {
                        typed = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.ink3)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear text")
                }
            }
            .padding(Theme.Space.s3)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.key).fill(Theme.well))
            .onAppear { store.resetTVTextNotice() }
            // Debounced live sync: every keystroke restarts the 250ms clock;
            // whole-string replace means dropped intermediates cost nothing.
            .task(id: typed) {
                guard typed != lastSent else { return }   // incl. first appear
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                lastSent = typed
                store.typeOnTV(session.id, typed)
            }

            Spacer(minLength: 0)
            TVRemotePad { store.pressTVKey(session.id, $0) }
                .frame(maxWidth: .infinity)
            Spacer(minLength: 0)
        }
        .padding(Theme.Space.s4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.bg)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .stroke(Theme.grab, lineWidth: 1)          // active surface = white edge
        )
    }
}

// The house remote pad: D-pad with the one solid-white OK grab, then
// menu / play-pause / home. Shared by the remote card and the Devices tab.
struct TVRemotePad: View {
    var press: (String) -> Void

    var body: some View {
        VStack(spacing: Theme.Space.s2) {
            arrow("chevron.up", "up")
            HStack(spacing: Theme.Space.s5) {
                arrow("chevron.left", "left")
                Button { press("select") } label: {
                    Text("OK").font(.custom(FontStack.ui.semibold, size: 13))
                        .foregroundStyle(Theme.bg)
                        .frame(width: 52, height: 52)
                        .background(Theme.grab)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                arrow("chevron.right", "right")
            }
            arrow("chevron.down", "down")
            HStack(spacing: Theme.Space.s5) {
                labeled("MENU", "menu")
                Button { press("play_pause") } label: {
                    Image(systemName: "playpause")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Theme.ink)
                        .frame(width: 52, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Play/Pause")
                labeled("HOME", "home")
            }
            .padding(.top, Theme.Space.s2)
        }
        .padding(.vertical, Theme.Space.s3)
    }

    private func arrow(_ symbol: String, _ key: String) -> some View {
        Button { press(key) } label: {
            Image(systemName: symbol).font(.system(size: 20, weight: .medium))
                .foregroundStyle(Theme.ink)
                .frame(width: 52, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(key)
    }

    private func labeled(_ label: String, _ key: String) -> some View {
        Button { press(key) } label: {
            Text(label)
                .font(.custom(FontStack.mono.medium, size: 10))
                .tracking(0.1 * 10)
                .foregroundStyle(Theme.ink2)
                .frame(width: 52, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
