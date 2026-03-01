import SwiftUI

/// Estimate noise floor from visible spectrum data.
/// Returns (noiseFloor, dynamicRange) for adaptive scaling.
func adaptiveNoiseFloor(_ data: [[Float]], loBin: Int, hiBin: Int) -> (floor: Float, range: Float) {
    guard !data.isEmpty, hiBin >= loBin else { return (-40, 50) }
    // Collect all visible bin values from recent rows
    let recentCount = min(data.count, 30)
    let startRow = data.count - recentCount
    var allVals = [Float]()
    allVals.reserveCapacity(recentCount * (hiBin - loBin + 1))
    for row in startRow..<data.count {
        let spectrum = data[row]
        for bin in loBin...min(hiBin, spectrum.count - 1) {
            allVals.append(spectrum[bin])
        }
    }
    guard !allVals.isEmpty else { return (-40, 50) }
    allVals.sort()
    // Noise floor = 25th percentile (robust against signals)
    let noiseFloor = allVals[allVals.count / 4]
    // Peak = 98th percentile (robust against spikes)
    let peak = allVals[min(allVals.count - 1, allVals.count * 98 / 100)]
    // Dynamic range: at least 15 dB, signals should pop
    let dynRange = max(15, peak - noiseFloor + 6)
    return (noiseFloor - 3, dynRange)
}

struct WaterfallView: View {
    let data: [[Float]]
    var sampleRate: Double = 12000
    var loFreq: Double = 0
    var hiFreq: Double = 0

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))
            guard !data.isEmpty, let totalBins = data.first?.count, totalBins > 0, sampleRate > 0 else { return }

            let nyquist = sampleRate / 2.0
            let binHz = nyquist / Double(totalBins)
            let lo = max(0, loFreq)
            let hi = hiFreq > 0 ? min(nyquist, hiFreq) : nyquist

            let loBin = max(0, Int(lo / binHz))
            let hiBin = min(totalBins - 1, Int(hi / binHz))
            let numBins = hiBin - loBin + 1
            guard numBins > 0 else { return }

            // Fixed noise floor (adaptive was hiding signals)
            let noiseFloor: Float = -60
            let dynRange: Float = 60

            let rows = data.count
            let displayCols = min(numBins, 500)
            let cellW = size.width / CGFloat(displayCols)
            let cellH = size.height / CGFloat(rows)

            for row in 0..<rows {
                let spectrum = data[row]
                for col in 0..<displayCols {
                    let srcBin = loBin + col * numBins / displayCols
                    guard srcBin < spectrum.count else { continue }
                    let val = spectrum[srcBin]
                    let norm = max(0, min(1, (val - noiseFloor) / dynRange))
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
