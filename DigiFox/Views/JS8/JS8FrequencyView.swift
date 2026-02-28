import SwiftUI

struct JS8FrequencyView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Dial").font(.caption2).foregroundStyle(.secondary)
                Text(fmt(settings.dialFrequency)).font(.system(.caption, design: .monospaced)).bold()
            }
            Spacer()
            VStack(spacing: 2) {
                Text("Offset").font(.caption2).foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    Button("-") { appState.txMessage.frequency = max(100, appState.txMessage.frequency - 50) }
                        .buttonStyle(.bordered).controlSize(.mini)
                    Text("\(Int(appState.txMessage.frequency)) Hz")
                        .font(.system(.caption, design: .monospaced)).frame(width: 60)
                    Button("+") { appState.txMessage.frequency = min(3000, appState.txMessage.frequency + 50) }
                        .buttonStyle(.bordered).controlSize(.mini)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("TX Freq").font(.caption2).foregroundStyle(.secondary)
                Text(fmt(settings.dialFrequency + appState.txMessage.frequency))
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(.red)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial)
    }

    private func fmt(_ f: Double) -> String { String(format: "%.6f MHz", f / 1_000_000) }
}
