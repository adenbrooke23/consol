import Foundation

// A household member. The PIN is the identity: there is no profile picker,
// and the entered 4-digit PIN resolves to exactly one profile. The hub
// enforces uniqueness (AuthStore does it for injected fixtures).

struct Profile: Identifiable, Hashable {
    let id: UUID
    var name: String
    var pin: String

    init(id: UUID = UUID(), name: String, pin: String) {
        self.id = id
        self.name = name
        self.pin = pin
    }
}
