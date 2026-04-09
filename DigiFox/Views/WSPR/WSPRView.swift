import SwiftUI

struct WSPRView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var settings: AppSettings

    @State private var isEditingFreq = false
    @State private var freqText = ""

    private var wsprMessages: [RxMessage] {
        appState.rxMessages.filter { $0.mode == .wspr }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Waterfall
                WaterfallView(data: appState.waterfallData,
                             sampleRate: appState.audioEngine.effectiveSampleRate,
                             loFreq: 1400, hiFreq: 1600)
                    .frame(height: 100)

                // Frequency display (editable)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Dial").font(.caption2).foregroundStyle(.secondary)
                        if isEditingFreq {
                            TextField("MHz", text: $freqText, onCommit: {
                                if let mhz = Double(freqText.replacingOccurrences(of: ",", with: ".")) {
                                    appState.setRigFrequency(UInt64(mhz * 1_000_000))
                                }
                                isEditingFreq = false
                            })
                            .font(.system(.caption, design: .monospaced)).bold()
                            .keyboardType(.decimalPad)
                            .frame(width: 110)
                            .textFieldStyle(.roundedBorder)
                        } else {
                            Text(String(format: "%.6f MHz", settings.dialFrequency / 1_000_000))
                                .font(.system(.caption, design: .monospaced)).bold()
                                .onTapGesture {
                                    freqText = String(format: "%.6f", settings.dialFrequency / 1_000_000)
                                    isEditingFreq = true
                                }
                        }
                    }
                    Spacer()
                    VStack(alignment: .center, spacing: 2) {
                        Text("Band").font(.caption2).foregroundStyle(.secondary)
                        Text(settings.selectedBand).font(.system(.caption, design: .monospaced))
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Mode").font(.caption2).foregroundStyle(.secondary)
                        Text("USB / WSPR").font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.green)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial)

                Divider()

                // Station info + power
                HStack {
                    GroupBox("Station") {
                        HStack(spacing: 16) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(settings.callsign.isEmpty ? "–" : settings.callsign)
                                    .foregroundStyle(settings.callsign.isEmpty ? .red : .primary)
                                Text(settings.grid.isEmpty ? "–" : String(settings.grid.prefix(4)))
                                    .foregroundStyle(settings.grid.isEmpty ? .red : .primary)
                            }
                            .font(.system(.caption, design: .monospaced))
                            Spacer()
                            Picker("Power", selection: $appState.wsprPower) {
                                ForEach(WSPRMessagePack.validPowers, id: \.self) { p in
                                    Text("\(p)dBm").tag(p)
                                }
                            }
                            .pickerStyle(.menu)
                            .font(.caption)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)

                Divider()

                // Decoded WSPR spots list
                if wsprMessages.isEmpty {
                    VStack {
                        Spacer()
                        Text("Waiting for WSPR decodes...")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                        Text("WSPR cycle time: 2 minutes")
                            .foregroundStyle(.secondary)
                            .font(.caption2)
                        Spacer()
                    }
                } else {
                    List(wsprMessages) { msg in
                        HStack {
                            Text(msg.timestamp, style: .time)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 55, alignment: .leading)
                            Text("\(msg.snr) dB")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(msg.snr > -20 ? .green : .orange)
                                .frame(width: 45, alignment: .trailing)
                            Text(String(format: "%.1f", msg.frequency))
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 50, alignment: .trailing)
                            Text(msg.text)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(1)
                        }
                    }
                    .listStyle(.plain)
                }

                Divider()

                // TX controls
                HStack(spacing: 12) {
                    Toggle("Auto TX", isOn: $appState.wsprTxEnabled)
                        .font(.caption)
                        .toggleStyle(.switch)
                        .frame(width: 120)

                    Button(action: {
                        if appState.isTransmitting {
                            appState.haltTx()
                        } else {
                            appState.transmitWSPR()
                        }
                    }) {
                        HStack {
                            Image(systemName: appState.isTransmitting ? "stop.fill" : "antenna.radiowaves.left.and.right")
                            Text(appState.isTransmitting ? "Halt" : "TX")
                        }
                        .font(.caption.bold())
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(appState.isTransmitting ? Color.red : Color.green)
                        .foregroundStyle(.white)
                        .cornerRadius(8)
                    }
                    .disabled(settings.callsign.isEmpty || settings.grid.isEmpty)

                    Spacer()

                    Text(appState.statusText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
            }
            .navigationTitle("WSPR")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { StatusToolbar() }
        }
    }
}
