import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        TabView(selection: $settings.digitalModeRaw) {
            FT8MainView()
                .tabItem { Label("FT8", systemImage: "waveform.path") }
                .tag(0)

            JS8MainView()
                .tabItem { Label("JS8Call", systemImage: "text.bubble") }
                .tag(1)

            ActivityView()
                .tabItem { Label("Aktivität", systemImage: "antenna.radiowaves.left.and.right") }
                .tag(2)

            SettingsView()
                .tabItem { Label("Einstellungen", systemImage: "gear") }
                .tag(3)
        }
    }
}

// MARK: - Shared toolbar content

struct StatusToolbar: ToolbarContent {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var settings: AppSettings

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            HStack(spacing: 8) {
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

// MARK: - FT8 Main View

struct FT8MainView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                WaterfallView(data: appState.waterfallData)
                    .frame(height: 120)
                ClockView()
                FT8FrequencyView()
                Divider()
                FT8MessageListView()
                    .frame(minHeight: 150)
                Divider()
                QSOPanelView()
            }
            .navigationTitle("FT8")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { StatusToolbar() }
            .onAppear { settings.digitalModeRaw = 0 }
        }
    }
}

// MARK: - JS8Call Main View

struct JS8MainView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                WaterfallView(data: appState.waterfallData)
                    .frame(height: 120)
                JS8FrequencyView()
                Divider()
                JS8MessageListView()
                Divider()
                TransmitView()
            }
            .navigationTitle("JS8Call")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { StatusToolbar() }
            .onAppear { settings.digitalModeRaw = 1 }
        }
    }
}

// MARK: - Activity View

struct ActivityView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        BandActivityView()
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
        if !ioKitAvailable { return .red }
        if rigConnected { return .green }
        if digirigConnected { return .green }
        if deviceCount > 0 { return .green }
        return .red
    }

    private var backgroundColor: Color {
        if rigConnected { return .green.opacity(0.15) }
        if digirigConnected { return .green.opacity(0.15) }
        return .red.opacity(0.1)
    }
}
