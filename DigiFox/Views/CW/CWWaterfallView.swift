import SwiftUI

/// Horizontal CW waterfall: time flows left→right, frequency bottom→top.
/// Monochrome (black/white). Zoomed to the audible CW bandwidth.
/// Adaptive noise floor for clear signal visibility.
struct CWWaterfallView: View {
    let data: [[Float]]
    let sampleRate: Double
    var centerFreq: Double = 700
    var displayBandwidth: Double = 800

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))
            guard !data.isEmpty, let bins = data.first?.count, bins > 0, sampleRate > 0 else { return }

            let binHz = sampleRate / Double(bins * 2)
            let loFreq = max(0, centerFreq - displayBandwidth / 2)
            let hiFreq = min(sampleRate / 2, centerFreq + displayBandwidth / 2)
            let loBin = max(0, Int(loFreq / binHz))
            let hiBin = min(bins - 1, Int(hiFreq / binHz))
            let numBins = hiBin - loBin + 1
            guard numBins > 0 else { return }

            // Fixed noise floor (adaptive was hiding signals)
            let noiseFloor: Float = -60
            let dynRange: Float = 60

            let rows = data.count
            let cellW = size.width / CGFloat(rows)
            let cellH = size.height / CGFloat(numBins)

            for col in 0..<rows {
                let spectrum = data[col]
                for bin in 0..<numBins {
                    let srcBin = loBin + bin
                    guard srcBin < spectrum.count else { continue }
                    let val = spectrum[srcBin]
                    let norm = max(0, min(1, (val - noiseFloor) / dynRange))
                    let x = CGFloat(col) * cellW
                    let y = size.height - CGFloat(bin + 1) * cellH
                    let rect = CGRect(x: x, y: y, width: cellW + 1, height: cellH + 1)
                    context.fill(Path(rect), with: .color(Color(white: Double(norm))))
                }
            }

            drawFreqScale(context: context, size: size, loFreq: loFreq, hiFreq: hiFreq)
        }
        .background(.black)
    }

    private func drawFreqScale(context: GraphicsContext, size: CGSize, loFreq: Double, hiFreq: Double) {
        let range = hiFreq - loFreq
        guard range > 0 else { return }
        let step = 100.0
        var freq = (loFreq / step).rounded(.up) * step
        while freq < hiFreq {
            let yFrac = 1.0 - (freq - loFreq) / range
            let y = CGFloat(yFrac) * size.height
            let tickPath = Path { p in
                p.move(to: CGPoint(x: size.width - 30, y: y))
                p.addLine(to: CGPoint(x: size.width - 25, y: y))
            }
            context.stroke(tickPath, with: .color(.gray.opacity(0.6)), lineWidth: 0.5)
            let label = Text("\(Int(freq))").font(.system(size: 7, design: .monospaced)).foregroundColor(.gray)
            context.draw(label, at: CGPoint(x: size.width - 13, y: y), anchor: .leading)
            freq += step
        }
    }
}
