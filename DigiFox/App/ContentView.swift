import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var settings: AppSettings

    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            FT8MainView()
                .tabItem { Label("FT8", systemImage: "waveform.path") }
                .tag(0)

            JS8MainView()
                .tabItem { Label("JS8Call", systemImage: "text.bubble") }
                .tag(1)

            CWView()
                .tabItem { Label("CW", systemImage: "dot.radiowaves.right") }
                .tag(4)

            WSPRView()
                .tabItem { Label("WSPR", systemImage: "wave.3.right") }
                .tag(5)

            ActivityView()
                .tabItem { Label("Activity", systemImage: "antenna.radiowaves.left.and.right") }
                .tag(2)

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gear") }
                .tag(3)
        }
        .onChange(of: selectedTab) { newTab in
            if let mode = DigitalMode(rawValue: newTab) {
                appState.switchMode(mode)
            }
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

                TransceiverStatusBadge(
                    hermesConnected: appState.hermesConnected,
                    isTransmitting: appState.isTransmitting
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
                WaterfallView(data: appState.waterfallData,
                             sampleRate: appState.audioEngine.effectiveSampleRate,
                             loFreq: 0, hiFreq: 3000)
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
                WaterfallView(data: appState.waterfallData,
                             sampleRate: appState.audioEngine.effectiveSampleRate,
                             loFreq: 0, hiFreq: 3000)
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

// MARK: - Transceiver Status Badge

struct TransceiverStatusBadge: View {
    let hermesConnected: Bool
    var isTransmitting: Bool = false

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: iconName).font(.caption).foregroundStyle(iconColor)
            Text(hermesConnected ? "Hermes" : "")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(hermesConnected ? .green : .secondary)
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Capsule().fill(backgroundColor))
    }

    private var iconName: String {
        if hermesConnected { return "antenna.radiowaves.left.and.right" }
        return "network.slash"
    }

    private var iconColor: Color {
        if isTransmitting { return .red }
        if hermesConnected { return .green }
        return .gray
    }

    private var backgroundColor: Color {
        if hermesConnected { return .green.opacity(0.15) }
        return .gray.opacity(0.1)
    }
}
