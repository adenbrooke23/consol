import Observation
import Foundation

// Owns sign-in. The PIN is the identity: the typed PIN goes to the hub, whose
// database resolves who it belongs to (POST /login/pin). The app ships no user
// roster, so adding a household member never needs an app build. Three
// consecutive wrong PINs start a 30s lockout (kept app-side). Previews and
// UITEST hooks inject a local roster and never touch the network.

@Observable
@MainActor
final class AuthStore {
    private(set) var state: AuthState = .loggedOut
    /// Preview/UITEST roster only. Empty in a normal launch, which is what
    /// routes attempt() to the hub.
    private(set) var profiles: [Profile]

    static let lockoutSeconds: TimeInterval = 30
    static let maxFailures = 3

    private var failures = 0
    private(set) var lockedUntil: Date?

    init(profiles: [Profile] = []) {
        // PIN uniqueness (a collision would merge two people): the hub
        // enforces it for real users; injected fixtures are filtered here.
        var seen = Set<String>()
        self.profiles = profiles.filter { seen.insert($0.pin).inserted }
    }

    // MARK: Passcode change

    enum PinChange { case success, wrongCurrent, notFourDigits, inUse, offline }

    /// Change the signed-in profile's passcode. The current PIN must be
    /// re-entered (possession check). The hub is the authority: it rejects
    /// a PIN another member already holds, and an unreachable hub means the
    /// change did not happen (login would stop working otherwise).
    func changePin(current: String, to newPin: String) async -> PinChange {
        guard var profile = currentProfile, profile.pin == current else { return .wrongCurrent }
        guard newPin.count == 4, newPin.allSatisfy(\.isNumber) else { return .notFourDigits }

        if !profiles.isEmpty {   // preview/UITEST roster: stay local
            guard let idx = profiles.firstIndex(where: { $0.id == profile.id }) else {
                return .wrongCurrent
            }
            guard !profiles.contains(where: { $0.id != profile.id && $0.pin == newPin }) else {
                return .inUse
            }
            profiles[idx].pin = newPin
            state = .loggedIn(profiles[idx])
            return .success
        }

        do {
            try await Hub.changeOwnPin(newPin)
        } catch let error as Hub.Error {
            return error.status == 409 ? .inUse : .offline
        } catch {
            return .offline
        }
        profile.pin = newPin
        state = .loggedIn(profile)   // the session's copy stays current
        return .success
    }

    // MARK: Sign-in

    /// Validate a completed 4-digit PIN. On success this does not flip to
    /// loggedIn: the login screen plays its 200ms success flash first, then
    /// calls commit(). Failure/lockout bookkeeping happens here; `.offline`
    /// means the hub is unreachable and is deliberately not a counted failure.
    @discardableResult
    func attempt(_ pin: String) async -> LoginOutcome {
        if let until = lockedUntil, until > Date.now {
            return .lockedOut(until: until)
        }

        if !profiles.isEmpty {   // preview/UITEST roster: no network
            if let profile = profiles.first(where: { $0.pin == pin }) {
                failures = 0
                lockedUntil = nil
                return .success(profile)
            }
            return registerFailure()
        }

        do {
            let reply = try await Hub.loginPin(pin)
            Hub.authToken = reply.token   // token in hand before the stage appears
            failures = 0
            lockedUntil = nil
            return .success(Profile(name: reply.name, pin: pin))
        } catch let error as Hub.Error where error.status == 401 {
            return registerFailure()
        } catch {
            return .offline
        }
    }

    private func registerFailure() -> LoginOutcome {
        failures += 1
        if failures >= Self.maxFailures {
            let until = Date.now.addingTimeInterval(Self.lockoutSeconds)
            lockedUntil = until
            failures = 0
            return .lockedOut(until: until)
        }
        return .wrong
    }

    /// Complete sign-in after the success flash. The hub token that
    /// authorizes every mutation is already in hand from attempt();
    /// the fetch below only covers the UITEST/preview path.
    func commit(_ profile: Profile) {
        failures = 0
        lockedUntil = nil
        state = .loggedIn(profile)
        Task { await fetchHubToken(force: Hub.authToken == nil) }
    }

    /// Exchange the signed-in PIN for a hub token. The root poll retries
    /// this only while the token is missing (hub was down, etc.).
    func fetchHubToken(force: Bool = false) async {
        guard force || Hub.authToken == nil, let profile = currentProfile else { return }
        if let token = try? await Hub.login(name: profile.name, pin: profile.pin) {
            Hub.authToken = token
        }
    }

    func signOut() {
        state = .loggedOut
        failures = 0
        lockedUntil = nil
        Hub.authToken = nil
    }

    var currentProfile: Profile? {
        if case let .loggedIn(p) = state { return p }
        return nil
    }
}
