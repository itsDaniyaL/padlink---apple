import Foundation
import Network
import Combine

struct DiscoveredReceiver: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let endpoint: NWEndpoint
    var host: String
    var controlPort: UInt16
    var inputPort: UInt16
    var screen: Bool
}

/// Browses for `_padlink._udp` services with Network.framework and resolves TXT
/// records to ports.
@MainActor
final class Discovery: ObservableObject {
    @Published private(set) var receivers: [DiscoveredReceiver] = []

    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let params = NWParameters()
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: PadLinkProtocol.serviceType, domain: nil), using: params)

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in self?.handle(results) }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
        receivers = []
    }

    private func handle(_ results: Set<NWBrowser.Result>) {
        var found: [DiscoveredReceiver] = []
        for result in results {
            guard case let .service(name, _, _, _) = result.endpoint else { continue }
            // The service is published on the TCP control port, so we connect
            // directly to `result.endpoint`. The input UDP port arrives via the
            // `in` TXT record (and again, authoritatively, in PAIR_OK).
            var inPort: UInt16 = 0
            var screen = false
            var displayName = name
            if case let .bonjour(txt) = result.metadata {
                inPort = UInt16(txt["in"] ?? "") ?? 0
                screen = (txt["screen"] == "1")
                displayName = txt["name"] ?? name
            }
            found.append(DiscoveredReceiver(
                name: displayName,
                endpoint: result.endpoint,
                host: name,
                controlPort: 0,        // unused: we connect via endpoint
                inputPort: inPort,     // fallback; PAIR_OK is authoritative
                screen: screen
            ))
        }
        receivers = found
    }

    /// Parse a scanned QR payload into a receiver (host + ports known directly).
    static func fromQR(_ payload: String) -> DiscoveredReceiver? {
        guard payload.hasPrefix("padlink://"),
              let comps = URLComponents(string: payload),
              let host = comps.queryItems?.first(where: { $0.name == "host" })?.value,
              let inStr = comps.queryItems?.first(where: { $0.name == "in" })?.value,
              let ctrlStr = comps.queryItems?.first(where: { $0.name == "ctrl" })?.value,
              let inPort = UInt16(inStr), let ctrlPort = UInt16(ctrlStr)
        else { return nil }
        let endpoint = NWEndpoint.hostPort(host: .init(host), port: .init(rawValue: ctrlPort)!)
        return DiscoveredReceiver(name: host, endpoint: endpoint, host: host,
                                  controlPort: ctrlPort, inputPort: inPort, screen: true)
    }
}
