import SwiftUI

@main
struct TapKitDemoApp: App {
    var body: some Scene {
        Window("CoreAudioTapKit Demo", id: "main") {
            ContentView()
                .frame(minWidth: 380, minHeight: 220)
        }
        .windowResizability(.contentSize)
    }
}
