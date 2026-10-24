import Foundation
import Network

// Finds the hub on the network. The hub's keeper advertises _consol-hub._tcp
// even while the hub itself is down, so the app can find the Mac and wake it.
// The app never blocks on discovery: the last-known host keeps working and
// this corrects it when the hub moves, or sets it on first launch.
//
// Requires NSBonjourServices in Info.plist and rides the same local-network
// permission the hub traffic already needs.

@MainActor
enum HubDiscovery {
    private static var browser: NWBrowser?
    private static var probe: NWConnection?

    /// Device builds always browse; the simulator reaches the hub on
    /// loopback and only exercises discovery under UITEST_DISCOVER=1.
    static func startIfEnabled() {
        #if targetEnvironment(simulator)
        guard ProcessInfo.processInfo.environment["UITEST_DISCOVER"] == "1" else { return }
        #endif
        start()
    }

    private static func start() {
        guard browser == nil else { return }
        let b = NWBrowser(for: .bonjour(type: "_consol-hub._tcp", domain: nil),
                          using: .tcp)
        b.stateUpdateHandler = { state in
            #if DEBUG
            print("HubDiscovery browser: \(state)")
            #endif
        }
        b.browseResultsChangedHandler = { results, _ in
            #if DEBUG
            print("HubDiscovery results: \(results.map(\.endpoint))")
            #endif
            guard let endpoint = results.first?.endpoint else { return }
            Task { @MainActor in resolve(endpoint) }
        }
        b.start(queue: .main)
        browser = b
    }

    /// One short TCP connection to the advertised endpoint. The ready
    /// path's remote address is the hub's host, and reaching it proves the
    /// service is real rather than a stale cache entry.
    private static func resolve(_ endpoint: NWEndpoint) {
        probe?.cancel()
        let connection = NWConnection(to: endpoint, using: .tcp)
        probe = connection
        connection.stateUpdateHandler = { state in
            #if DEBUG
            print("HubDiscovery probe: \(state) remote=\(String(describing: connection.currentPath?.remoteEndpoint))")
            #endif
            switch state {
            case .ready:
                var found: String?
                if let remote = connection.currentPath?.remoteEndpoint,
                   case let .hostPort(host, _) = remote {
                    switch host {
                    case let .ipv4(address):
                        // Stringified addresses can carry an interface suffix
                        // ("192.168.1.20%en0") that has no place in a URL.
                        found = "\(address)".split(separator: "%").first.map(String.init)
                    case let .ipv6(address):
                        // Link-local scopes don't survive in a URL; wait for
                        // a routable address or IPv4 instead.
                        found = address.isLinkLocal ? nil
                            : "\(address)".split(separator: "%").first.map { "[\($0)]" }
                    case let .name(name, _):
                        found = name
                    @unknown default:
                        found = nil
                    }
                }
                Task { @MainActor in
                    #if DEBUG
                    print("HubDiscovery apply: found=\(found ?? "nil") current=\(Hub.host)")
                    #endif
                    if let found, found != Hub.host {
                        Hub.host = found   // next poll/request uses it
                    }
                    probe?.cancel()
                    probe = nil
                }
            case .failed, .cancelled:
                Task { @MainActor in probe = nil }
            default:
                break
            }
        }
        connection.start(queue: .main)
    }
}
