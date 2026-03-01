import SwiftUI

struct WSPRView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                // Frequency display
                VStack(spacing: 4) {
                    Text("WSPR Beacon")
                        .font(.headline)
                    Text(String(format: "%.4f MHz", settings.dialFrequency / 1_000_000))
                        .font(.system(.title, design: .monospaced))
                        .foregroundStyle(.green)
                    Text(settings.selectedBand)
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding()

                // Station info
                GroupBox("Station") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Callsign:")
                            Spacer()
                            Text(settings.callsign.isEmpty ? "–" : settings.callsign)
                                .foregroundStyle(settings.callsign.isEmpty ? .red : .primary)
                        }
                        HStack {
                            Text("Grid:")
                            Spacer()
                            Text(settings.grid.isEmpty ? "–" : String(settings.grid.prefix(4)))
                                .foregroundStyle(settings.grid.isEmpty ? .red : .primary)
                        }
                        HStack {
                            Text("Power:")
                            Spacer()
                            Picker("Power", selection: $appState.wsprPower) {
                                ForEach(WSPRMessagePack.validPowers, id: \.self) { p in
                                    Text("\(p) dBm").tag(p)
                                }
                            }
                            .pickerStyle(.menu)
                        }
                    }
                    .font(.system(.body, design: .monospaced))
                }
                .padding(.horizontal)

                // WSPR message preview
                GroupBox("Message") {
                    let msg = WSPRMessage(
                        callsign: settings.callsign,
                        grid: String(settings.grid.prefix(4)),
                        power: appState.wsprPower
                    )
                    Text(msg.displayText)
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .padding(.horizontal)

                // TX button
                Button(action: {
                    if appState.isTransmitting {
                        appState.haltTx()
                    } else {
                        appState.transmitWSPR()
                    }
                }) {
                    HStack {
                        Image(systemName: appState.isTransmitting ? "stop.fill" : "antenna.radiowaves.left.and.right")
                        Text(appState.isTransmitting ? "TX Halt" : "Transmit WSPR")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(appState.isTransmitting ? Color.red : Color.green)
                    .foregroundStyle(.white)
                    .cornerRadius(12)
                }
                .padding(.horizontal)
                .disabled(settings.callsign.isEmpty || settings.grid.isEmpty)

                // Status
                Text(appState.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // Info
                Text("WSPR transmits a ~110s beacon at even minutes.\nSignal bandwidth: ~6 Hz")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Spacer()
            }
            .navigationTitle("WSPR")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { StatusToolbar() }
        }
    }
}
