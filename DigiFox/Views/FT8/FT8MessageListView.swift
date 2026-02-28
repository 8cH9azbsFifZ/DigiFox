import SwiftUI

struct FT8MessageListView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        List {
            if appState.rxMessages.isEmpty {
                Text("Keine Nachrichten empfangen")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .listRowBackground(Color.clear)
            } else {
                ForEach(appState.rxMessages.filter { $0.mode == .ft8 }) { msg in
                    HStack(spacing: 0) {
                        Text(msg.timestamp, format: .dateTime.hour().minute().second())
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 55, alignment: .leading)
                        Text(String(format: "%+3d", msg.snr))
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(snrColor(msg.snr))
                            .frame(width: 30, alignment: .trailing)
                        Text(String(format: " %+4.1f", msg.deltaTime))
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                        Text(String(format: " %4d", Int(msg.frequency)))
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.cyan)
                            .frame(width: 40, alignment: .trailing)
                        Text(" ~ ")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text(msg.text)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(messageColor(msg))
                            .lineLimit(1)
                    }
                    .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                }
            }
        }
        .listStyle(.plain)
        .font(.system(.caption, design: .monospaced))
    }

    private func snrColor(_ snr: Int) -> Color {
        if snr >= 0 { return .green }
        if snr >= -10 { return .yellow }
        if snr >= -18 { return .orange }
        return .red
    }

    private func messageColor(_ msg: RxMessage) -> Color {
        if msg.isCQ { return .green }
        if msg.isMyCall { return .red }
        return .primary
    }
}
