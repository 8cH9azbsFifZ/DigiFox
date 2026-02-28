import SwiftUI

@main
struct DigiFoxApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .environmentObject(appState.settings)
        }
    }
}
