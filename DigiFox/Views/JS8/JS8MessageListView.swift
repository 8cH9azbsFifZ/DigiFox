import SwiftUI

struct JS8MessageListView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        List {
            if appState.rxMessages.isEmpty {
                Text("Keine Nachrichten empfangen")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .listRowBackground(Color.clear)
            } else {
                ForEach(appState.rxMessages.filter { $0.mode == .js8 }) { msg in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(msg.timestamp, style: .time).font(.caption2).foregroundStyle(.secondary)
                            Text("\(Int(msg.frequency)) Hz").font(.caption2).foregroundStyle(.blue)
                            Text("\(msg.snr) dB").font(.caption2).foregroundStyle(msg.snr > -10 ? .green : .orange)
                            if let speed = msg.js8Speed {
                                Text(speed.name).font(.caption2).foregroundStyle(.purple)
                            }
                            Spacer()
                        }
                        Text(msg.text)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(msg.isDirected ? .yellow : .primary)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .listStyle(.plain)
    }
}
