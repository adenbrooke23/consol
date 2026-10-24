import SwiftUI

// The app at its most reduced: black screen, wordmark, one line, four boxes.
// No profile picker: the PIN is the identity. A hidden numberPad field drives
// the boxes (hardware keyboard also works). Wrong PIN shakes + clears; 3 wrong
// = 30s lockout with a mono countdown; correct flashes lemon then the app
// crossfades to the Stage.

enum PinBoxState { case normal, error, success }

struct LoginView: View {
    @Environment(AuthStore.self) private var auth
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool

    @State private var pin = ""
    @State private var boxState: PinBoxState = .normal
    @State private var shakeX: CGFloat = 0
    @State private var lockedUntil: Date?
    @State private var errorTick = 0
    @State private var successTick = 0
    @State private var checking = false      // waiting on the hub's verdict
    @State private var offline = false       // last attempt couldn't reach the hub

    private var locked: Bool { (lockedUntil ?? .distantPast) > .now }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()

            VStack(spacing: Theme.Space.s5) {
                wordmark
                messageLine
                pinRow
            }

            // Hidden field: system numeric keyboard + hardware digits.
            TextField("", text: $pin)
                .keyboardType(.numberPad)
                .focused($focused)
                .disabled(locked)
                .opacity(0.001)
                .frame(width: 1, height: 1)
                .accessibilityHidden(true)
        }
        .onAppear {
            focused = true
            #if DEBUG
            // Drive a real hub login for screenshots:
            // UITEST_LOGIN_PIN=1111 types the PIN as if by hand.
            if pin.isEmpty, let scripted = ProcessInfo.processInfo.environment["UITEST_LOGIN_PIN"] {
                pin = scripted
            }
            #endif
        }
        .onChange(of: pin) { _, newValue in handleInput(newValue) }
        .sensoryFeedback(.error, trigger: errorTick)
        .sensoryFeedback(.success, trigger: successTick)
        .task(id: lockedUntil) { await runLockout() }
    }

    // MARK: Pieces
    private var wordmark: some View {
        VStack(spacing: Theme.Space.s4) {
            // The mark sits above the name, kept small.
            Image("ConsolLogo")
                .resizable().scaledToFit()
                .frame(height: 64)
                .accessibilityHidden(true)
            Text("CONSOL")
                .foregroundStyle(Theme.ink)
                .font(Typo.display.font)
                .tracking(Typo.display.tracking)
        }
    }

    @ViewBuilder private var messageLine: some View {
        if locked, let until = lockedUntil {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = max(0, Int(until.timeIntervalSince(context.date).rounded(.up)))
                Text("Try again in 0:\(String(format: "%02d", remaining))")
                    .typo(.label).foregroundStyle(Theme.alert)
            }
        } else if offline {
            Text("Can't reach the hub. Check the Mac and try again.")
                .typo(.body).foregroundStyle(Theme.alert)
        } else {
            Text(checking ? "Checking…" : "Enter your PIN to log in")
                .typo(.body).foregroundStyle(Theme.Lav.l400)
        }
    }

    private var pinRow: some View {
        HStack(spacing: Theme.Space.s3) {
            ForEach(0..<4, id: \.self) { i in
                PinBox(
                    filled: i < pin.count,
                    active: i == pin.count && !locked,
                    state: boxState,
                    reduceMotion: reduceMotion
                )
            }
        }
        .offset(x: shakeX)
        .contentShape(Rectangle())
        .onTapGesture { if !locked { focused = true } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("PIN entry, \(pin.count) of 4 digits")
    }

    // MARK: Logic
    private func handleInput(_ raw: String) {
        let digits = String(raw.filter(\.isNumber).prefix(4))
        if digits != pin { pin = digits; return }   // sanitized; re-entry is a no-op
        if boxState != .normal { boxState = .normal }
        if offline { offline = false }
        if pin.count == 4 { validate() }
    }

    private func validate() {
        guard !checking else { return }
        checking = true
        Task { @MainActor in
            let outcome = await auth.attempt(pin)   // hub's DB is the roster
            checking = false
            switch outcome {
            case let .success(profile):
                boxState = .success
                successTick += 1
                try? await Task.sleep(for: .seconds(0.2))
                auth.commit(profile)                 // app crossfades to Stage
            case .wrong:
                errorTick += 1
                fail()
            case let .lockedOut(until):
                errorTick += 1
                boxState = .error
                lockedUntil = until
                pin = ""
            case .offline:
                offline = true
                errorTick += 1
                fail()
            }
        }
    }

    private func fail() {
        boxState = .error
        if reduceMotion {
            // No shake: hold the alert border briefly, then clear.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(0.5))
                clear()
            }
        } else {
            Task { @MainActor in
                for v in [CGFloat(-7), 6, -4, 3, 0] {
                    withAnimation(.linear(duration: 0.06)) { shakeX = v }
                    try? await Task.sleep(for: .seconds(0.06))
                }
                clear()
            }
        }
    }

    private func clear() {
        pin = ""
        boxState = .normal
    }

    private func runLockout() async {
        guard let until = lockedUntil else { return }
        let delay = until.timeIntervalSinceNow
        if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
        lockedUntil = nil
        clear()
        focused = true
    }
}

private struct PinBox: View {
    var filled: Bool
    var active: Bool
    var state: PinBoxState
    var reduceMotion: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Theme.well)
            .frame(width: 56, height: 68)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(border, lineWidth: 1))
            .overlay {
                Circle()
                    .fill(Theme.ink)
                    .frame(width: 12, height: 12)
                    .opacity(filled ? 1 : 0)
                    .scaleEffect(reduceMotion ? 1 : (filled ? 1 : 0.4))
                    .animation(.spring(duration: 0.14), value: filled)
            }
            .accessibilityHidden(true)
    }

    private var border: Color {
        switch state {
        case .error: return Theme.alert
        case .success: return Theme.signal
        case .normal: return active ? Theme.Lav.l500 : Theme.rule
        }
    }
}

#Preview {
    LoginView()
        .environment(AuthStore())
        .preferredColorScheme(.dark)
}
