import SwiftUI
import Combine

@main
struct PadLinkMacApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("PadLink") {
            DashboardView()
                .environmentObject(model)
                .frame(minWidth: 460, minHeight: 420)
        }
        .windowResizability(.contentSize)
    }
}

/// Owns the receiver server, virtual controller, and screen-share controller.
@MainActor
final class AppModel: ObservableObject {
    let controller: VirtualController
    let screen: ScreenShareController
    let server: ReceiverServer

    private var cancellables = Set<AnyCancellable>()

    init() {
        let controller = VirtualController()
        let screen = ScreenShareController()
        self.controller = controller
        self.screen = screen
        self.server = ReceiverServer(controller: controller, screen: screen)

        // These are nested ObservableObjects; SwiftUI only re-renders views bound
        // to AppModel when *AppModel's* objectWillChange fires. Forward each
        // child's change so the dashboard (PIN, status, controller state) updates.
        for child in [server.objectWillChange, controller.objectWillChange, screen.objectWillChange] {
            child.sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &cancellables)
        }
    }
}
