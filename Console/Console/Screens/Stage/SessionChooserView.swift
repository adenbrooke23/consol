import SwiftUI

// The new-session chooser. A black pill panel (1.5pt white border, radius 28:
// the one sanctioned exception to the 16pt max), 20pt padding, width clamped
// 380…520 so it always fits the space freed by the parked stack. × top-right
// always cancels; ← top-left (step 2 only) goes back.
//
// Step 1 what (kind) → Step 2 where (outputs grouped Speakers / TVs). A TV is a
// single tap. Speakers are multi-select (a group), confirmed with the footer
// action. Status per row: FREE in lemon, or the owning card's title in alert.

struct SessionChooserView: View {
    @Environment(SessionStore.self) private var store
    var onCancel: () -> Void
    var onFinish: () -> Void

    private enum Step { case what, whereTo }
    @State private var step: Step = .what
    @State private var kind: SessionKind = .music
    @State private var selectedSpeakers: Set<String> = []

    private let whats: [(SessionKind, String, String)] = [
        (.music, "music.note", "Music"),
        (.liveTV, "sportscourt", "Live TV & Sports"),
        (.film, "film", "Movies & Shows"),
        (.apps, "square.grid.2x2", "Apps"),
    ]

    private var tvs: [Output] { store.outputs.filter { $0.kind == .tv } }
    private var speakers: [Output] { store.outputs.filter { $0.kind == .speaker } }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s3) {
            controls
            Text(stepLabel).typo(.label).foregroundStyle(Theme.ink2)
            if step == .what { whatRows } else { whereStep }
        }
        .padding(20)
        .frame(minWidth: 380, maxWidth: 520, alignment: .leading)
        .background(Theme.bg)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.pill))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.pill)
                .stroke(Theme.grab, lineWidth: 1.5)          // white pill border
        )
        #if DEBUG
        .onAppear {
            if ProcessInfo.processInfo.environment["UITEST_WHERE"] == "1" {
                kind = .music; step = .whereTo
            }
        }
        #endif
    }

    private var controls: some View {
        HStack {
            if step == .whereTo {
                IconButton(systemName: "chevron.left", a11y: "Back") {
                    withAnimation(Theme.Motion.snappy) { step = .what; selectedSpeakers = [] }
                }
                .padding(.leading, -14)
            }
            Spacer(minLength: 0)
            IconButton(systemName: "xmark", a11y: "Cancel", action: onCancel)
                .padding(.trailing, -14)
        }
    }

    // MARK: Step 1: what
    private var whatRows: some View {
        VStack(spacing: Theme.Space.s2) {
            ForEach(whats, id: \.0) { k, icon, label in
                OptionRow(icon: icon, label: label, trailing: nil,
                          trailingColor: Theme.ink3, selected: false) {
                    kind = k
                    withAnimation(Theme.Motion.snappy) { step = .whereTo }
                }
            }
        }
    }

    // MARK: Step 2: where
    private var whereStep: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s3) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.s3) {
                    group("SPEAKERS", speakers, multi: true)
                    group("TVS", tvs, multi: false)
                }
            }
            .frame(maxHeight: 360)

            if !selectedSpeakers.isEmpty { confirmSpeakers }
        }
    }

    private func group(_ title: String, _ outputs: [Output], multi: Bool) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s2) {
            Text(title).typo(.label).foregroundStyle(Theme.ink3)
                .padding(.leading, Theme.Space.s2)
            ForEach(outputs) { output in
                let owner = store.owner(of: output)
                OptionRow(
                    icon: output.kind == .tv ? "tv" : "hifispeaker",
                    label: output.name,
                    trailing: owner?.title.uppercased() ?? "FREE",
                    trailingColor: owner == nil ? Theme.signal : Theme.alert,
                    selected: multi && selectedSpeakers.contains(output.name)
                ) {
                    if multi { toggleSpeaker(output.name) }
                    else { birth(on: [output]) }         // TV = single tap
                }
            }
        }
    }

    private var confirmSpeakers: some View {
        Button {
            let outs = speakers.filter { selectedSpeakers.contains($0.name) }
            birth(on: outs)
        } label: {
            HStack {
                Text(playHereLabel)
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
                    .stroke(Theme.grab, lineWidth: 1.5)   // no lemon fill; white border marks the action
            )
        }
        .buttonStyle(.plain)
    }

    private var playHereLabel: String {
        let n = selectedSpeakers.count
        return n == 1 ? "Play on \(selectedSpeakers.first!)" : "Group \(n) rooms & play"
    }

    private var stepLabel: String {
        step == .what ? "1/2 · Play what"
                      : "2/2 · Where: \(kind.label)"
    }

    private func toggleSpeaker(_ name: String) {
        withAnimation(Theme.Motion.press) {
            if selectedSpeakers.contains(name) { selectedSpeakers.remove(name) }
            else { selectedSpeakers.insert(name) }
        }
    }

    private func birth(on outputs: [Output]) {
        withAnimation(Theme.Motion.birth) {
            store.create(kind: kind, on: outputs)        // ends any owner (take-over)
        }
        onFinish()
    }
}
