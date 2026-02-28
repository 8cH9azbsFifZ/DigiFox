import Foundation
import Accelerate

/// FT8 Modulator — TX chain.
///
/// Pipeline: FT8Message → pack (77 bits) → CRC-14 (91 bits) → LDPC encode (174 bits)
///         → Gray-coded 8-FSK symbols (58 data + 21 sync = 79) → GFSK audio waveform.
///
/// Generates continuous-phase FSK with raised-cosine amplitude ramp.
final class FT8Modulator {

    /// Audio frequency of the lowest tone (Hz).
    var baseFrequency: Double = 1000.0

    /// Amplitude (0.0 – 1.0).
    var amplitude: Double = 0.5

    /// Duration of raised-cosine ramp at start/end (seconds).
    var rampDuration: Double = 0.005

    // MARK: - Public API

    /// Modulate an FT8Message into audio samples at 12 kHz.
    func modulate(_ message: FT8Message) -> [Float] {
        let payload = FT8MessagePack.pack(message)
        let withCRC = FT8CRC.append(to: payload)
        let codeword = LDPC.encode(withCRC)
        let symbols = bitsToSymbols(codeword)
        let frame = insertSync(symbols)
        return synthesize(frame)
    }

    /// Modulate raw 77-bit payload (for testing or pre-packed messages).
    func modulatePayload(_ payload: [UInt8]) -> [Float] {
        let withCRC = FT8CRC.append(to: payload)
        let codeword = LDPC.encode(withCRC)
        let symbols = bitsToSymbols(codeword)
        let frame = insertSync(symbols)
        return synthesize(frame)
    }

    // MARK: - Symbol Mapping

    /// Convert 174 coded bits → 58 data symbols (3 bits each, Gray-coded).
    private func bitsToSymbols(_ bits: [UInt8]) -> [Int] {
        var symbols = [Int]()
        symbols.reserveCapacity(FT8Protocol.dataSymbolCount)
        for i in stride(from: 0, to: FT8Protocol.codedBits, by: FT8Protocol.bitsPerSymbol) {
            let b0 = Int(bits[i])
            let b1 = Int(bits[i + 1])
            let b2 = Int(bits[i + 2])
            let natural = (b0 << 2) | (b1 << 1) | b2
            symbols.append(FT8Protocol.grayEncode[natural])
        }
        return symbols
    }

    /// Insert Costas sync symbols into the 58 data symbols to form 79-symbol frame.
    private func insertSync(_ dataSymbols: [Int]) -> [Int] {
        var frame = [Int](repeating: 0, count: FT8Protocol.symbolCount)
        let costas = FT8Protocol.costas

        // Place Costas arrays
        for i in 0..<7 {
            frame[i]      = costas[i]       // positions 0-6
            frame[36 + i] = costas[i]       // positions 36-42
            frame[72 + i] = costas[i]       // positions 72-78
        }

        // Place data symbols at data positions
        let dataPos = FT8Protocol.dataPositions
        for (idx, pos) in dataPos.enumerated() {
            if idx < dataSymbols.count {
                frame[pos] = dataSymbols[idx]
            }
        }

        return frame
    }

    // MARK: - GFSK Synthesis

    /// Synthesize continuous-phase GFSK audio from 79 tone symbols.
    private func synthesize(_ symbols: [Int]) -> [Float] {
        let sampleRate = FT8Protocol.sampleRate
        let symbolSamples = FT8Protocol.symbolSamples
        let totalSamples = FT8Protocol.frameSamples
        let rampSamples = Int(rampDuration * sampleRate)

        var samples = [Float](repeating: 0, count: totalSamples)
        var phase: Double = 0

        for (symIdx, symbol) in symbols.enumerated() {
            let freq = baseFrequency + Double(symbol) * FT8Protocol.toneSpacing
            let phaseIncrement = 2.0 * .pi * freq / sampleRate

            for j in 0..<symbolSamples {
                let sampleIdx = symIdx * symbolSamples + j
                guard sampleIdx < totalSamples else { break }

                let value = sin(phase) * amplitude
                samples[sampleIdx] = Float(value)
                phase += phaseIncrement

                // Keep phase in [0, 2π) to prevent floating-point drift
                if phase >= 2.0 * .pi {
                    phase -= 2.0 * .pi
                }
            }
        }

        // Apply raised-cosine ramp at start and end
        applyRamp(&samples, rampSamples: rampSamples)

        return samples
    }

    /// Apply raised-cosine ramp to avoid click artifacts.
    private func applyRamp(_ samples: inout [Float], rampSamples: Int) {
        let count = samples.count
        guard rampSamples > 0, count > 2 * rampSamples else { return }

        for i in 0..<rampSamples {
            let ramp = Float(0.5 * (1.0 - cos(.pi * Double(i) / Double(rampSamples))))
            samples[i] *= ramp
            samples[count - 1 - i] *= ramp
        }
    }

    // MARK: - Utility

    /// Duration of the generated audio in seconds.
    var frameDuration: Double {
        return Double(FT8Protocol.frameSamples) / FT8Protocol.sampleRate
    }
}
