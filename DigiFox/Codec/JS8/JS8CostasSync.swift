import Foundation

enum JS8CostasSync {
    static let pattern = JS8Protocol.costas

    static func referenceSymbols() -> [Int] {
        var symbols = [Int](repeating: 0, count: JS8Protocol.symbolCount)
        for i in 0..<7 {
            symbols[i] = pattern[i]
            symbols[36 + i] = pattern[i]
            symbols[72 + i] = pattern[i]
        }
        return symbols
    }

    static func correlate(
        spectrum: [[Float]],
        toneSpacing: Double,
        freqRange: ClosedRange<Double>
    ) -> [(timeOffset: Int, freqOffset: Double, score: Double)] {
        var candidates = [(Int, Double, Double)]()
        let nTime = spectrum.count
        guard nTime >= JS8Protocol.symbolCount, let nFreq = spectrum.first?.count, nFreq > 0 else { return [] }

        let freqBinWidth = JS8Protocol.sampleRate / Double(nFreq * 2)
        let toneBins = max(1, Int(toneSpacing / freqBinWidth))
        let minBin = max(0, Int(freqRange.lowerBound / freqBinWidth))
        let maxBin = min(nFreq - 8 * toneBins, Int(freqRange.upperBound / freqBinWidth))
        guard maxBin > minBin else { return [] }

        for t0 in 0..<(nTime - JS8Protocol.symbolCount + 1) {
            for f0 in stride(from: minBin, to: max(minBin + 1, maxBin), by: 1) {
                var score: Double = 0
                var count = 0
                for group in [0, 36, 72] {
                    for i in 0..<7 {
                        let si = t0 + group + i
                        guard si < nTime else { continue }
                        let bin = f0 + pattern[i] * toneBins
                        guard bin < nFreq else { continue }
                        score += Double(spectrum[si][bin])
                        count += 1
                    }
                }
                if count > 0 {
                    let avg = score / Double(count)
                    if avg > 0.5 { candidates.append((t0, Double(f0) * freqBinWidth, avg)) }
                }
            }
        }
        return candidates.sorted { $0.2 > $1.2 }.prefix(10).map { ($0.0, $0.1, $0.2) }
    }
}
