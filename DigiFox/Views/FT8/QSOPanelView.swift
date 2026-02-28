import SwiftUI

struct QSOPanelView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        VStack(spacing: 6) {
            // QSO partner info
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("DX Call").font(.caption2).foregroundStyle(.secondary)
                    TextField("Rufzeichen", text: $appState.dxCall)
                        .font(.system(.subheadline, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)
                        .frame(width: 110)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("DX Grid").font(.caption2).foregroundStyle(.secondary)
                    TextField("Grid", text: $appState.dxGrid)
                        .font(.system(.subheadline, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)
                        .frame(width: 70)
                }
                Spacer()
                // TX Even/Odd
                VStack(spacing: 2) {
                    Text("TX").font(.caption2).foregroundStyle(.secondary)
                    Picker("", selection: $appState.txEven) {
                        Text("Gerade").tag(true)
                        Text("Ungerade").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 140)
                }
            }
            .padding(.horizontal, 12)

            // TX Message buttons (TX1-TX6 like WSJT-X)
            VStack(spacing: 4) {
                ForEach(Array(appState.txMessages.enumerated()), id: \.offset) { idx, msg in
                    HStack(spacing: 6) {
                        Button {
                            appState.selectedTxMessage = idx
                        } label: {
                            HStack {
                                Image(systemName: appState.selectedTxMessage == idx ? "largecircle.fill.circle" : "circle")
                                    .font(.caption)
                                    .foregroundStyle(appState.selectedTxMessage == idx ? .red : .secondary)
                                Text("Tx\(idx + 1)")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 28, alignment: .leading)
                                Text(msg)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(appState.selectedTxMessage == idx ? .red : .primary)
                                    .lineLimit(1)
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 12)

            // Control buttons
            HStack(spacing: 12) {
                // Auto-sequence
                Toggle(isOn: $appState.autoSequence) {
                    Label("Auto", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption)
                }
                .toggleStyle(.button)
                .tint(.blue)

                Spacer()

                // Log QSO
                Button {
                    appState.logQSO()
                } label: {
                    Label("Log", systemImage: "book.closed")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .tint(.green)
                .disabled(appState.dxCall.isEmpty)

                // Enable TX / Halt TX
                Button {
                    appState.txEnabled.toggle()
                } label: {
                    Text(appState.txEnabled ? "TX Halt" : "TX Ein")
                        .font(.subheadline).bold()
                        .frame(width: 80)
                }
                .buttonStyle(.borderedProminent)
                .tint(appState.txEnabled ? .red : .green)
            }
            .padding(.horizontal, 12)
        }
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }
}
