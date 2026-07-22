import SwiftUI

@main
struct AnnoyOApp: App {
    @StateObject private var controller = PlayerController()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(controller: controller)
        } label: {
            StatusBarIcon(isPlaying: controller.playbackState.isPlaying)
        }
        .menuBarExtraStyle(.window)
    }
}
