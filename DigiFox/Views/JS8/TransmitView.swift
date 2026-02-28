import SwiftUI

struct TransmitView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Circle()
                    .fill(appState.isTransmitting ? .red : (appState.isReceiving ? .green : .gray))
                    .frame(width: 10, height: 10)
                Text(appState.statusText).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Picker("Modus", selection: $settings.speedRaw) {
                    ForEach(JS8Speed.allCases) { s in Text(s.name).tag(s.rawValue) }
                }
                .pickerStyle(.segmented)
                .frame(width: 250)
            }
            .padding(.horizontal)

            HStack {
                TextField("Nachricht senden...", text: $appState.txMessage.text)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
                Button(action: {
                    appState.mode == .standalone ? appState.transmit() : appState.sendNetworkMessage()
                }) {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .disabled(appState.txMessage.text.isEmpty || appState.isTransmitting)
                .tint(.red)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .background(.ultraThinMaterial)
    }
}
