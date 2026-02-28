import SwiftUI

struct NetworkClientView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    Circle().fill(appState.networkClient.isConnected ? .green : .red).frame(width: 12, height: 12)
                    Text(appState.networkClient.isConnected ? "Verbunden" : "Getrennt").font(.subheadline)
                    Spacer()
                    Button(appState.networkClient.isConnected ? "Trennen" : "Verbinden") {
                        appState.networkClient.isConnected ? appState.disconnectNetwork() : appState.connectNetwork()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(appState.networkClient.isConnected ? .red : .green)
                }
                .padding()

                if let err = appState.networkClient.lastError {
                    Text("Fehler: \(err)").font(.caption).foregroundStyle(.red).padding(.horizontal)
                }

                Divider()

                List {
                    Section("API-Nachrichten") {
                        if appState.networkClient.receivedMessages.isEmpty {
                            Text("Keine Nachrichten").foregroundStyle(.secondary)
                        } else {
                            ForEach(appState.networkClient.receivedMessages) { msg in
                                VStack(alignment: .leading) {
                                    Text(msg.type).font(.caption).bold().foregroundStyle(.blue)
                                    Text(msg.value).font(.system(.caption, design: .monospaced))
                                }
                            }
                        }
                    }
                    Section("Stationen") {
                        ForEach(appState.stations) { station in
                            HStack {
                                Text(station.callsign).font(.system(.body, design: .monospaced)).bold()
                                Spacer()
                                VStack(alignment: .trailing) {
                                    Text("\(station.snr) dB").font(.caption)
                                    Text(station.lastHeard, style: .time).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                Divider()
                TransmitView()
            }
            .navigationTitle("Netzwerk-Client")
        }
    }
}
