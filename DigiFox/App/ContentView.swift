import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        TabView {
            MainView()
                .tabItem { Label("DigiFox", systemImage: "waveform") }

            ActivityView()
                .tabItem { Label("Aktivität", systemImage: "antenna.radiowaves.left.and.right") }

            SettingsView()
                .tabItem { Label("Einstellungen", systemImage: "gear") }
        }
    }
}

// MARK: - Main View (mode-dependent)

struct MainView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                WaterfallView(data: appState.waterfallData)
                    .frame(height: 120)

                if settings.digitalMode == .ft8 {
                    ClockView()
                    FT8FrequencyView()
                    Divider()
                    FT8MessageListView()
                        .frame(minHeight: 150)
                    Divider()
                    QSOPanelView()
                } else {
                    JS8FrequencyView()
                    Divider()
                    JS8MessageListView()
                    Divider()
                    TransmitView()
                }
            }
            .navigationTitle("DigiFox")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: 8) {
                        // Mode Picker
                        Picker("Modus", selection: $settings.digitalModeRaw) {
                            Text("FT8").tag(0)
                            Text("JS8").tag(1)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 110)

                        Text(settings.callsign.isEmpty ? "–" : settings.callsign)
                            .font(.caption)
                            .foregroundStyle(settings.callsign.isEmpty ? .red : .green)

                        USBStatusBadge(
                            ioKitAvailable: appState.ioKitAvailable,
                            deviceCount: appState.usbDevices.count,
                            digirigConnected: appState.digirigConnected,
                            rigConnected: appState.radioState.isConnected
                        )
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: {
                        appState.isReceiving ? appState.stopReceiving() : appState.startReceiving()
                    }) {
                        Text(appState.isReceiving ? "Stop" : "Start")
                            .fontWeight(.semibold)
                            .foregroundStyle(appState.isReceiving ? .red : .green)
                    }
                }
            }
        }
    }
}

// MARK: - Activity View (mode-dependent)

struct ActivityView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        if settings.digitalMode == .ft8 {
            BandActivityView()
        } else {
            NetworkClientView()
        }
    }
}

// MARK: - USB Status Badge

struct USBStatusBadge: View {
    let ioKitAvailable: Bool
    let deviceCount: Int
    let digirigConnected: Bool
    let rigConnected: Bool

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: iconName).font(.caption).foregroundStyle(iconColor)
            if digirigConnected {
                Text("Digirig")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(rigConnected ? .green : .orange)
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Capsule().fill(backgroundColor))
    }

    private var iconName: String {
        if !ioKitAvailable { return "usb.slash" }
        if rigConnected { return "antenna.radiowaves.left.and.right" }
        if digirigConnected { return "cable.connector" }
        if deviceCount > 0 { return "cable.connector" }
        return "usb"
    }

    private var iconColor: Color {
        if !ioKitAvailable { return .gray }
        if rigConnected { return .green }
        if digirigConnected { return .orange }
        if deviceCount > 0 { return .yellow }
        return .gray
    }

    private var backgroundColor: Color {
        if rigConnected { return .green.opacity(0.15) }
        if digirigConnected { return .orange.opacity(0.15) }
        return .clear
    }
}
