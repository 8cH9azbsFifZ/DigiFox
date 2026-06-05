import SwiftUI

@main
struct DigiFoxApp: App {
    @StateObject private var appState = AppState()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .environmentObject(appState.settings)
        }
        .onChange(of: scenePhase) { newPhase in
            switch newPhase {
            case .background:
                if appState.hermesConnected {
                    Task { await appState.disconnectHermes() }
                }
            case .active:
                break  // User reconnects manually via UI
            default:
                break
            }
        }
    }
}
