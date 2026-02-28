import Foundation

class JS8Modulator {
    private let ldpc = LDPCCodec()

    func modulate(message: String, frequency: Double, speed: JS8Speed) -> [Float] {
        let payload = PackMessage.pack(message)
        let withCRC = JS8CRC.append(to: payload)
        let codeword = ldpc.encode(withCRC)

        // 174 coded bits → 58 data symbols (3 bits each)
        var dataSymbols = [Int]()
        for i in stride(from: 0, to: min(codeword.count, 174), by: 3) {
            guard i + 2 < codeword.count else { break }
            let s = Int(codeword[i]) << 2 | Int(codeword[i+1]) << 1 | Int(codeword[i+2])
            dataSymbols.append(s)
        }

        // Build 79-symbol frame: Costas + data
        var symbols = [Int](repeating: 0, count: JS8Protocol.symbolCount)
        let c = JS8Protocol.costas
        for i in 0..<7 { symbols[i] = c[i]; symbols[36+i] = c[i]; symbols[72+i] = c[i] }
        for (di, pos) in JS8Protocol.dataPositions.enumerated() where di < dataSymbols.count {
            symbols[pos] = dataSymbols[di]
        }

        return generateAudio(symbols: symbols, frequency: frequency, speed: speed)
    }

    private func generateAudio(symbols: [Int], frequency: Double, speed: JS8Speed) -> [Float] {
        let nsps = speed.symbolSamples
        let ts = JS8Protocol.toneSpacing(for: speed)
        let sr = JS8Protocol.sampleRate
        let total = nsps * symbols.count
        var audio = [Float](repeating: 0, count: total)
        var phase: Double = 0

        for (si, sym) in symbols.enumerated() {
            let freq = frequency + Double(sym) * ts
            let dphi = 2.0 * .pi * freq / sr
            for j in 0..<nsps {
                audio[si * nsps + j] = Float(sin(phase))
                phase += dphi
                if phase > 2.0 * .pi { phase -= 2.0 * .pi }
            }
        }

        // Raised-cosine ramp (5ms)
        let ramp = Int(0.005 * sr)
        for i in 0..<min(ramp, total) {
            let w = Float(0.5 * (1.0 - cos(.pi * Double(i) / Double(ramp))))
            audio[i] *= w
            audio[total - 1 - i] *= w
        }
        return audio
    }
}
