import SwiftUI

struct TransmitView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Picker("Modus", selection: $settings.speedRaw) {
                    ForEach(JS8Speed.allCases) { s in Text(s.name).tag(s.rawValue) }
                }
                .pickerStyle(.segmented)
            }
            .padding(.horizontal)

            HStack {
                TextField("Nachricht senden...", text: $appState.txMessage.text)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
                Button(action: {
                    appState.transmitJS8()
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
