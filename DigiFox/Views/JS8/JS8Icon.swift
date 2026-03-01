import SwiftUI

/// Stylized "JS8" text icon with a signal wave accent, for use as tab bar icon.
struct JS8Icon: View {
    var size: CGFloat = 24
    var color: Color = .primary

    var body: some View {
        Canvas { ctx, canvasSize in
            let s = min(canvasSize.width, canvasSize.height)
            let scale = s / 100.0

            // "J" letter
            var j = Path()
            j.addRoundedRect(in: CGRect(x: 8 * scale, y: 20 * scale, width: 8 * scale, height: 40 * scale),
                             cornerSize: CGSize(width: 2 * scale, height: 2 * scale))
            // J hook
            j.move(to: CGPoint(x: 12 * scale, y: 60 * scale))
            j.addQuadCurve(to: CGPoint(x: 2 * scale, y: 50 * scale),
                           control: CGPoint(x: 2 * scale, y: 62 * scale))
            j.addLine(to: CGPoint(x: 2 * scale, y: 46 * scale))
            j.addQuadCurve(to: CGPoint(x: 8 * scale, y: 56 * scale),
                           control: CGPoint(x: 6 * scale, y: 56 * scale))
            j.closeSubpath()
            // J top serif
            j.addRoundedRect(in: CGRect(x: 4 * scale, y: 18 * scale, width: 16 * scale, height: 6 * scale),
                             cornerSize: CGSize(width: 2 * scale, height: 2 * scale))
            ctx.fill(j, with: .color(color))

            // "S" letter
            var s_path = Path()
            let sx: CGFloat = 28 * scale
            s_path.move(to: CGPoint(x: sx + 18 * scale, y: 26 * scale))
            s_path.addQuadCurve(to: CGPoint(x: sx, y: 28 * scale),
                                control: CGPoint(x: sx + 8 * scale, y: 18 * scale))
            s_path.addQuadCurve(to: CGPoint(x: sx + 18 * scale, y: 44 * scale),
                                control: CGPoint(x: sx - 6 * scale, y: 38 * scale))
            s_path.addQuadCurve(to: CGPoint(x: sx, y: 56 * scale),
                                control: CGPoint(x: sx + 24 * scale, y: 52 * scale))
            s_path.addQuadCurve(to: CGPoint(x: sx + 4 * scale, y: 60 * scale),
                                control: CGPoint(x: sx - 4 * scale, y: 62 * scale))
            ctx.stroke(s_path, with: .color(color), style: StrokeStyle(lineWidth: 6 * scale, lineCap: .round, lineJoin: .round))

            // "8" letter
            let ex: CGFloat = 60 * scale
            var eight = Path()
            // top circle of 8
            eight.addEllipse(in: CGRect(x: ex, y: 18 * scale, width: 18 * scale, height: 20 * scale))
            // bottom circle of 8 (slightly wider)
            eight.addEllipse(in: CGRect(x: ex - 1 * scale, y: 36 * scale, width: 20 * scale, height: 24 * scale))
            ctx.stroke(eight, with: .color(color), style: StrokeStyle(lineWidth: 5 * scale, lineCap: .round))

            // Signal wave accent (top right)
            var wave = Path()
            let wy: CGFloat = 10 * scale
            wave.move(to: CGPoint(x: 78 * scale, y: wy))
            wave.addQuadCurve(to: CGPoint(x: 86 * scale, y: wy),
                              control: CGPoint(x: 82 * scale, y: wy - 8 * scale))
            wave.addQuadCurve(to: CGPoint(x: 94 * scale, y: wy),
                              control: CGPoint(x: 90 * scale, y: wy + 8 * scale))
            ctx.stroke(wave, with: .color(color), style: StrokeStyle(lineWidth: 3 * scale, lineCap: .round))

            // Second wave (smaller)
            var wave2 = Path()
            let wy2: CGFloat = 70 * scale
            wave2.move(to: CGPoint(x: 82 * scale, y: wy2))
            wave2.addQuadCurve(to: CGPoint(x: 88 * scale, y: wy2),
                               control: CGPoint(x: 85 * scale, y: wy2 - 5 * scale))
            wave2.addQuadCurve(to: CGPoint(x: 94 * scale, y: wy2),
                               control: CGPoint(x: 91 * scale, y: wy2 + 5 * scale))
            ctx.stroke(wave2, with: .color(color), style: StrokeStyle(lineWidth: 2.5 * scale, lineCap: .round))
        }
        .frame(width: size, height: size)
    }
    /// Render as UIImage for use in tabItem
    @MainActor
    static func uiImage(size: CGFloat = 25) -> UIImage {
        let renderer = ImageRenderer(content: JS8Icon(size: size, color: .primary))
        renderer.scale = UIScreen.main.scale
        return renderer.uiImage ?? UIImage(systemName: "text.bubble")!
    }
}
