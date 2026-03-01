import SwiftUI

struct CWView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // CW Waterfall (horizontal, monochrome, bandwidth-adapted)
                CWWaterfallView(
                    data: appState.waterfallData,
                    sampleRate: appState.audioEngine.effectiveSampleRate,
                    centerFreq: 700,
                    displayBandwidth: 800
                )
                .frame(height: 100)

                // Frequency & speed display
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Dial").font(.caption2).foregroundStyle(.secondary)
                        Text(fmt(settings.dialFrequency))
                            .font(.system(.caption, design: .monospaced)).bold()
                    }
                    Spacer()
                    VStack(alignment: .center, spacing: 2) {
                        Text("Speed").font(.caption2).foregroundStyle(.secondary)
                        HStack(spacing: 4) {
                            Button("-") { appState.cwSpeed = max(5, appState.cwSpeed - 1) }
                                .buttonStyle(.bordered).controlSize(.mini)
                            Text("\(appState.cwSpeed) WPM")
                                .font(.system(.caption, design: .monospaced)).frame(width: 60)
                            Button("+") { appState.cwSpeed = min(40, appState.cwSpeed + 1) }
                                .buttonStyle(.bordered).controlSize(.mini)
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Mode").font(.caption2).foregroundStyle(.secondary)
                        HStack(spacing: 4) {
                            if appState.cwKeying {
                                Circle().fill(.red).frame(width: 8, height: 8)
                            } else if appState.cwDecoding {
                                Circle().fill(.green).frame(width: 8, height: 8)
                            }
                            Text("CW").font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.orange).bold()
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial)

                Divider()

                // Decoded CW text (RX)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("RX Decoded").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if appState.cwDecoding {
                            Text("Decoding...").font(.caption2).foregroundStyle(.green)
                        }
                        Button { appState.clearCWDecoded() } label: {
                            Image(systemName: "trash").font(.caption)
                        }
                        .disabled(appState.cwDecodedText.isEmpty)
                    }
                    .padding(.horizontal)
                    .padding(.top, 6)

                    ScrollView {
                        Text(appState.cwDecodedText.isEmpty ? "Waiting for CW signal..." : appState.cwDecodedText)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(appState.cwDecodedText.isEmpty ? .secondary : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal)
                    }
                    .frame(maxHeight: .infinity)
                }

                Divider()

                // TX Log
                if !appState.cwLog.isEmpty {
                    List(appState.cwLog.indices, id: \.self) { i in
                        Text(appState.cwLog[i])
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(appState.cwLog[i].hasPrefix("TX:") ? .red : .primary)
                    }
                    .listStyle(.plain)
                    .frame(maxHeight: 120)

                    Divider()
                }

                // Macros
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        cwMacro("CQ", "CQ CQ CQ DE \(settings.callsign) \(settings.callsign) K")
                        cwMacro("73", "73 DE \(settings.callsign) SK")
                        cwMacro("RST", "UR RST 599 599")
                        cwMacro("TU", "TU 73")
                        cwMacro("QTH", "QTH \(settings.grid)")
                    }
                    .padding(.horizontal)
                }
                .padding(.vertical, 6)

                Divider()

                // Input
                HStack(spacing: 8) {
                    TextField("CW text...", text: $appState.cwText)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)
                        .onSubmit { appState.sendCW() }

                    Button { appState.sendCW() } label: {
                        MorseKeyIcon(size: 20, color: .white)
                            .padding(8)
                            .background(Circle().fill(.orange))
                    }
                    .disabled(appState.cwText.isEmpty || !appState.radioState.isConnected || appState.cwKeying)

                    Button { appState.stopCW() } label: {
                        Image(systemName: "stop.fill")
                            .foregroundStyle(.white)
                            .padding(8)
                            .background(Circle().fill(.red))
                    }
                    .disabled(!appState.cwKeying)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .navigationTitle("CW")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { StatusToolbar() }
        }
    }

    private func cwMacro(_ label: String, _ text: String) -> some View {
        Button(label) {
            appState.cwText = text
            appState.sendCW()
        }
        .buttonStyle(.bordered)
        .tint(.orange)
        .controlSize(.small)
        .disabled(!appState.radioState.isConnected || appState.cwKeying)
    }

    private func fmt(_ f: Double) -> String { String(format: "%.6f MHz", f / 1_000_000) }
}
