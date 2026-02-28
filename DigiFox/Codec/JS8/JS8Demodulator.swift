import Foundation

class JS8Demodulator {
    private let ldpc = LDPCCodec()
    private let fft: FFTProcessor

    init(fftSize: Int = 4096) {
        self.fft = FFTProcessor(size: fftSize)
    }

    func demodulate(samples: [Float], speed: JS8Speed, freqRange: ClosedRange<Double> = 100...3000) -> [DemodResult] {
        let nsps = speed.symbolSamples
        let ts = JS8Protocol.toneSpacing(for: speed)
        let nSymbols = samples.count / nsps
        guard nSymbols >= JS8Protocol.symbolCount else { return [] }

        // Compute spectrogram
        var spectrogram = [[Float]]()
        for i in 0..<nSymbols {
            let start = i * nsps
            let end = min(start + nsps, samples.count)
            spectrogram.append(fft.magnitudeSpectrum(Array(samples[start..<end])))
        }

        // Find signals via Costas correlation
        let candidates = JS8CostasSync.correlate(spectrum: spectrogram, toneSpacing: ts, freqRange: freqRange)

        var results = [DemodResult]()
        for c in candidates {
            if let r = demodCandidate(spectrogram: spectrogram, t0: c.timeOffset, freq: c.freqOffset, ts: ts, nsps: nsps) {
                results.append(r)
            }
        }
        return results
    }

    private func demodCandidate(spectrogram: [[Float]], t0: Int, freq: Double, ts: Double, nsps: Int) -> DemodResult? {
        let binW = JS8Protocol.sampleRate / Double(fft.size)
        let baseBin = Int(freq / binW)
        let toneBins = max(1, Int(ts / binW))

        // Extract soft symbols
        var llr = [Double](repeating: 0, count: JS8Protocol.codewordBits)
        for (si, pos) in JS8Protocol.dataPositions.enumerated() {
            let idx = t0 + pos
            guard idx < spectrogram.count else { return nil }
            var energies = [Double](repeating: 0, count: 8)
            for tone in 0..<8 {
                let bin = baseBin + tone * toneBins
                if bin >= 0 && bin < spectrogram[idx].count {
                    energies[tone] = Double(spectrogram[idx][bin])
                }
            }
            for bit in 0..<3 {
                var p0: Double = 0, p1: Double = 0
                for tone in 0..<8 {
                    if (tone >> (2 - bit)) & 1 == 0 { p0 += energies[tone] } else { p1 += energies[tone] }
                }
                llr[si * 3 + bit] = log(max(p0, 1e-10) / max(p1, 1e-10))
            }
        }

        guard let decoded = ldpc.decode(llr) else { return nil }
        guard JS8CRC.validate(decoded) else { return nil }

        let message = PackMessage.unpack(Array(decoded.prefix(JS8Protocol.payloadBits)))
        let snr = estimateSNR(spectrogram: spectrogram, t0: t0, baseBin: baseBin, toneBins: toneBins)

        return DemodResult(
            frequency: freq,
            snr: snr,
            deltaTime: Double(t0 * nsps) / JS8Protocol.sampleRate,
            bits: decoded,
            message: message
        )
    }

    private func estimateSNR(spectrogram: [[Float]], t0: Int, baseBin: Int, toneBins: Int) -> Double {
        var signal: Double = 0, noise: Double = 0, sc = 0, nc = 0
        for i in 0..<7 {
            let si = t0 + i
            guard si < spectrogram.count else { continue }
            let bin = baseBin + JS8Protocol.costas[i] * toneBins
            if bin >= 0 && bin < spectrogram[si].count { signal += Double(spectrogram[si][bin]); sc += 1 }
            for off in [-2, -1, 1, 2] {
                let nb = bin + off * toneBins
                if nb >= 0 && nb < spectrogram[si].count { noise += Double(spectrogram[si][nb]); nc += 1 }
            }
        }
        guard sc > 0 && nc > 0 else { return 0 }
        let avgN = noise / Double(nc)
        guard avgN > 0 else { return 30 }
        return 10 * log10((signal / Double(sc)) / avgN)
    }
}
