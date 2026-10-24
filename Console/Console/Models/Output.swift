import Foundation

// A physical output the house can route to. Devices are resources, not
// destinations: each belongs to at most one session at a time. "Busy" is
// derived by the store from whether any session currently names this output.

struct Output: Identifiable, Hashable {
    enum Kind { case tv, speaker }
    let id: String        // the name is the identity for our purposes
    var kind: Kind
    var name: String { id }

    init(_ name: String, _ kind: Kind) { self.id = name; self.kind = kind }
}
