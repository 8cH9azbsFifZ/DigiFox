import SwiftUI

struct FT8FrequencyView: View {
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
                    Button("-") { appState.txFrequency = max(200, appState.txFrequency - 50) }
                        .buttonStyle(.bordered).controlSize(.mini)
                    Text("\(Int(appState.txFrequency)) Hz")
                        .font(.system(.caption, design: .monospaced)).frame(width: 60)
                    Button("+") { appState.txFrequency = min(3000, appState.txFrequency + 50) }
                        .buttonStyle(.bordered).controlSize(.mini)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("TX Freq").font(.caption2).foregroundStyle(.secondary)
                Text(fmt(settings.dialFrequency + appState.txFrequency))
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(.red)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial)
    }

    private func fmt(_ f: Double) -> String { String(format: "%.6f MHz", f / 1_000_000) }
}
