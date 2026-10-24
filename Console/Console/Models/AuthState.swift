import Foundation

// Sign-in state machine. lockedOut carries the wall-clock time the lockout
// ends so the login screen can render a live countdown.
enum AuthState: Equatable {
    case loggedOut
    case lockedOut(until: Date)
    case loggedIn(Profile)
}

// Result of a single PIN attempt, returned to the login screen so it can drive
// the shake / lockout / success animations.
enum LoginOutcome: Equatable {
    case success(Profile)
    case wrong
    case lockedOut(until: Date)
    case offline          // hub unreachable: not a wrong PIN, not counted
}
