import SwiftUI

/// A straight Morse key icon drawn as a SwiftUI Shape.
///
///  Visual:
///      ┌──┐
///      │  │   ← knob
///  ────┘  └────
///  │          │  ← lever arm
///  └──┐  ┌──┘
///     │  │     ← pivot
///  ┌──┴──┴──┐
///  └────────┘  ← base
struct MorseKeyShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height

        var p = Path()

        // Base plate
        let baseH = h * 0.15
        let baseY = h - baseH
        p.addRoundedRect(in: CGRect(x: w * 0.1, y: baseY, width: w * 0.8, height: baseH),
                         cornerSize: CGSize(width: baseH * 0.3, height: baseH * 0.3))

        // Pivot post (center column from base up)
        let pivotW = w * 0.12
        let pivotH = h * 0.2
        let pivotX = (w - pivotW) / 2
        let pivotY = baseY - pivotH
        p.addRoundedRect(in: CGRect(x: pivotX, y: pivotY, width: pivotW, height: pivotH + 2),
                         cornerSize: CGSize(width: pivotW * 0.2, height: pivotW * 0.2))

        // Lever arm (horizontal bar across, slightly above pivot)
        let armH = h * 0.08
        let armY = pivotY - armH * 0.3
        p.addRoundedRect(in: CGRect(x: w * 0.05, y: armY, width: w * 0.9, height: armH),
                         cornerSize: CGSize(width: armH * 0.4, height: armH * 0.4))

        // Knob (on top of lever, right-center)
        let knobW = w * 0.22
        let knobH = h * 0.28
        let knobX = w * 0.62
        let knobY = armY - knobH + armH * 0.15
        p.addRoundedRect(in: CGRect(x: knobX, y: knobY, width: knobW, height: knobH),
                         cornerSize: CGSize(width: knobW * 0.35, height: knobH * 0.25))

        // Contact points (two small dots on base below lever ends)
        let dotR = w * 0.03
        p.addEllipse(in: CGRect(x: w * 0.22 - dotR, y: baseY - dotR * 2, width: dotR * 2, height: dotR * 2))
        p.addEllipse(in: CGRect(x: w * 0.78 - dotR, y: baseY - dotR * 2, width: dotR * 2, height: dotR * 2))

        return p
    }
}

/// Morse key icon as an Image-compatible View for use in tab bars and buttons.
struct MorseKeyIcon: View {
    var size: CGFloat = 24
    var color: Color = .primary

    var body: some View {
        MorseKeyShape()
            .fill(color)
            .frame(width: size, height: size)
    }

    /// Render as UIImage for use in tabItem
    static func uiImage(size: CGFloat = 25) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return renderer.image { ctx in
            let rect = CGRect(origin: .zero, size: CGSize(width: size, height: size))
            let path = MorseKeyShape().path(in: rect)
            UIColor.label.setFill()
            ctx.cgContext.addPath(path.cgPath)
            ctx.cgContext.fillPath()
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        MorseKeyIcon(size: 64, color: .orange)
        MorseKeyIcon(size: 32, color: .primary)
        MorseKeyIcon(size: 24, color: .secondary)
    }
    .padding()
}
