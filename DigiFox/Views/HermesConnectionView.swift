import SwiftUI

/// View for discovering and connecting to Hermes SDR devices over Ethernet.
struct HermesConnectionView: View {
    @EnvironmentObject var appState: AppState
    @State private var manualIP = ""
    @State private var scanning = false

    var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack {
                Image(systemName: "network")
                    .foregroundColor(.blue)
                Text("Hermes SDR")
                    .font(.headline)
                Spacer()
                if appState.hermesConnected {
                    Label("Verbunden", systemImage: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.caption)
                }
            }

            // Scan button
            HStack {
                Button(action: { startScan() }) {
                    HStack {
                        if scanning {
                            ProgressView()
                                .scaleEffect(0.8)
                        }
                        Text(scanning ? "Suche..." : "Netzwerk scannen")
                    }
                }
                .disabled(scanning || appState.hermesConnected)
                .buttonStyle(.bordered)

                Spacer()

                if appState.hermesConnected {
                    Button("Trennen") {
                        Task { await appState.disconnectHermes() }
                    }
                    .foregroundColor(.red)
                    .buttonStyle(.bordered)
                }
            }

            // Manual IP entry
            if !appState.hermesConnected {
                HStack {
                    TextField("IP-Adresse (z.B. 192.168.1.100)", text: $manualIP)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.numbersAndPunctuation)
                        .autocorrectionDisabled()
                    Button("Direkt") {
                        startScan(directIP: manualIP)
                    }
                    .disabled(manualIP.isEmpty)
                    .buttonStyle(.bordered)
                }
            }

            // Device list
            if !appState.hermesDevices.isEmpty && !appState.hermesConnected {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Gefundene Geräte:")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    ForEach(appState.hermesDevices) { device in
                        Button(action: { appState.connectHermes(device) }) {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(device.displayName)
                                        .font(.system(.body, design: .monospaced))
                                    Text("MAC: \(device.mac)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Image(systemName: "arrow.right.circle")
                                    .foregroundColor(.blue)
                            }
                            .padding(8)
                            .background(Color(.systemGray6))
                            .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Hermes controls (when connected)
            if appState.hermesConnected {
                Divider()

                VStack(spacing: 12) {
                    // LNA Gain
                    HStack {
                        Text("LNA Gain")
                            .font(.caption)
                        Slider(value: Binding(
                            get: { Double(appState.hermesLNAGain) },
                            set: { appState.setHermesLNAGain(Int($0)) }
                        ), in: 0...60, step: 1)
                        Text("\(appState.hermesLNAGain) dB")
                            .font(.caption)
                            .frame(width: 50, alignment: .trailing)
                    }

                    // TX Power
                    HStack {
                        Text("TX Power")
                            .font(.caption)
                        Slider(value: Binding(
                            get: { Double(appState.hermesTxPower) },
                            set: { appState.setHermesTxPower(Int($0)) }
                        ), in: 0...100, step: 5)
                        Text("\(appState.hermesTxPower)%")
                            .font(.caption)
                            .frame(width: 50, alignment: .trailing)
                    }
                }
            }
        }
        .padding()
    }

    private func startScan(directIP: String? = nil) {
        scanning = true
        appState.scanHermesDevices(directIP: directIP)
        // Auto-stop scanning indicator after timeout
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await MainActor.run { scanning = false }
        }
    }
}
