import SwiftUI

struct WaterfallView: View {
    let data: [[Float]]
    private let minDB: Float = -40
    private let maxDB: Float = 10

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))
            guard !data.isEmpty, let cols = data.first?.count, cols > 0 else { return }
            let rows = data.count
            let displayCols = min(cols, 500)
            let cellW = size.width / CGFloat(displayCols)
            let cellH = size.height / CGFloat(rows)
            for row in 0..<rows {
                for col in 0..<displayCols {
                    let srcCol = col * cols / displayCols
                    let val = data[row][srcCol]
                    let norm = max(0, min(1, (val - minDB) / (maxDB - minDB)))
                    let rect = CGRect(x: CGFloat(col) * cellW, y: CGFloat(rows - 1 - row) * cellH,
                                      width: cellW + 1, height: cellH + 1)
                    context.fill(Path(rect), with: .color(colorMap(norm)))
                }
            }
        }
        .background(.black)
    }

    private func colorMap(_ v: Float) -> Color {
        let d = Double(v)
        if d < 0.25 { return Color(red: 0, green: 0, blue: d * 4) }
        if d < 0.5  { return Color(red: 0, green: (d - 0.25) * 4, blue: 1) }
        if d < 0.75 { return Color(red: (d - 0.5) * 4, green: 1, blue: 1 - (d - 0.5) * 4) }
        return Color(red: 1, green: 1 - (d - 0.75) * 4, blue: 0)
    }
}
