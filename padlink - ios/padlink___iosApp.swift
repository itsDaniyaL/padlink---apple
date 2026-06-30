import SwiftUI

@main
struct PadLinkiOSApp: App {
    @StateObject private var discovery = Discovery()
    @StateObject private var connection = ConnectionManager()
    @StateObject private var layout = LayoutStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(discovery)
                .environmentObject(connection)
                .environmentObject(layout)
                .preferredColorScheme(.dark)
                .onAppear {
                    discovery.start()
                    // Keep the receiver's displayed format in sync with the phone.
                    connection.currentLayout = layout.style.wireId
                    layout.onStyleChange = { connection.setLayout($0.wireId) }
                }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var connection: ConnectionManager

    var body: some View {
        switch connection.state {
        case .disconnected, .error: DiscoveryView()
        case .connecting: ProgressView("Connecting…")
        case .needsPin: PinView()
        case .paired: ControllerView()
        }
    }
}
