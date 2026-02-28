import SwiftUI

struct ClockView: View {
    @EnvironmentObject var appState: AppState
    let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()
    @State private var progress: Double = 0
    @State private var secondsLeft: Int = 0
    @State private var isEvenSlot: Bool = true

    var body: some View {
        HStack(spacing: 8) {
            // Cycle progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.gray.opacity(0.2))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(appState.isTransmitting ? Color.red : (isEvenSlot ? Color.blue : Color.green))
                        .frame(width: geo.size.width * progress)
                }
            }
            .frame(height: 6)

            Text("\(secondsLeft)s")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 25)

            // Even/Odd indicator
            Text(isEvenSlot ? "E" : "O")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(isEvenSlot ? .blue : .green)
                .frame(width: 15)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .onReceive(timer) { _ in
            let now = Date()
            let calendar = Calendar.current
            let second = calendar.component(.second, from: now)
            let ms = calendar.component(.nanosecond, from: now)
            let totalSeconds = Double(second) + Double(ms) / 1_000_000_000
            let cyclePos = totalSeconds.truncatingRemainder(dividingBy: 15.0)
            progress = cyclePos / 15.0
            secondsLeft = Int(15.0 - cyclePos)
            isEvenSlot = (second / 15) % 2 == 0
        }
    }
}
