import SwiftUI

@main
struct MacCleanApp: App {
    var body: some Scene {
        WindowGroup("Mac Clean") {
            ContentView()
                .frame(minWidth: 920, minHeight: 620)
        }
        .defaultSize(width: 1120, height: 780)
    }
}
