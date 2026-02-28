import SwiftUI

struct BandActivityView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Band-Aktivität")
                    .font(.caption).bold().foregroundStyle(.secondary)
                Spacer()
                Text("\(appState.stations.count) Stationen")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)

            List {
                ForEach(appState.stations.sorted { $0.lastHeard > $1.lastHeard }) { station in
                    HStack {
                        Text(station.callsign)
                            .font(.system(.subheadline, design: .monospaced))
                            .bold()
                        if !station.grid.isEmpty {
                            Text(station.grid)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.cyan)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 1) {
                            Text("\(station.snr) dB")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(station.snr >= -10 ? .green : .orange)
                            Text(station.lastHeard, style: .time)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        appState.startQSO(with: station.callsign, grid: station.grid)
                    }
                }
            }
            .listStyle(.plain)
        }
    }
}
