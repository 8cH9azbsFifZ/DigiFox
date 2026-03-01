import Foundation
import Accelerate

/// WSPR Modulator — TX chain.
///
/// Pipeline: WSPRMessage → pack (50 bits) → convolutional encode (162 bits)
///         → interleave → merge with sync vector → 4-FSK audio waveform.
///
/// Reuses the same continuous-phase FSK synthesis approach as FT8Modulator.
final class WSPRModulator {

    /// Audio frequency of the lowest tone (Hz). WSPR signals are in 1400-1600 Hz range.
    var baseFrequency: Double = 1500.0

    /// Amplitude (0.0 – 1.0).
    var amplitude: Double = 0.5

    /// Duration of raised-cosine ramp at start/end (seconds).
    var rampDuration: Double = 0.005

    // MARK: - Public API

    /// Modulate a WSPR message into audio samples at 12 kHz.
    func modulate(_ message: WSPRMessage) -> [Float] {
        let bits = WSPRMessagePack.pack(message)
        let encoded = convolutionalEncode(bits)
        let interleaved = interleave(encoded)
        let symbols = mergeWithSync(interleaved)
        return synthesize(symbols)
    }

    // MARK: - Convolutional Encoding

    /// K=32, rate 1/2 convolutional encoder.
    /// Takes 50 message bits, outputs 162 coded bits.
    /// Uses tail-biting: register initialized to zero, 81 coded output pairs.
    private func convolutionalEncode(_ messageBits: [UInt8]) -> [UInt8] {
        var reg: UInt32 = 0
        var output = [UInt8]()
        output.reserveCapacity(WSPRProtocol.codedBits)

        // Encode 50 message bits + 31 tail bits (zeros) = 81 input bits → 162 output bits
        for i in 0..<81 {
            let bit: UInt32 = i < messageBits.count ? UInt32(messageBits[i]) : 0
            reg = (reg << 1) | bit

            // Output bit 1: parity of (reg & poly1)
            let p1 = parity32(reg & WSPRProtocol.poly1)
            // Output bit 2: parity of (reg & poly2)
            let p2 = parity32(reg & WSPRProtocol.poly2)

            output.append(p1)
            output.append(p2)
        }

        return output
    }

    /// Compute parity (number of 1-bits mod 2) of a 32-bit value
    private func parity32(_ x: UInt32) -> UInt8 {
        var v = x
        v ^= v >> 16
        v ^= v >> 8
        v ^= v >> 4
        v ^= v >> 2
        v ^= v >> 1
        return UInt8(v & 1)
    }

    // MARK: - Interleaving

    /// Bit-reversal interleaver: reorder 162 coded bits
    private func interleave(_ bits: [UInt8]) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: 162)
        var j = 0
        for i in 0..<256 {
            let rev = WSPRProtocol.interleaveIndex(i)
            if rev < 162 {
                if j < bits.count {
                    result[rev] = bits[j]
                    j += 1
                }
            }
        }
        return result
    }

    // MARK: - Symbol Generation

    /// Merge interleaved data bits with sync vector to produce 4-FSK symbols.
    /// Channel symbol = sync[i] + 2 * data[i], giving values 0-3.
    private func mergeWithSync(_ dataBits: [UInt8]) -> [Int] {
        var symbols = [Int](repeating: 0, count: WSPRProtocol.symbolCount)
        for i in 0..<WSPRProtocol.symbolCount {
            let sync = WSPRProtocol.syncVector[i]
            let data = i < dataBits.count ? Int(dataBits[i]) : 0
            symbols[i] = sync + 2 * data
        }
        return symbols
    }

    // MARK: - 4-FSK Synthesis

    /// Synthesize continuous-phase 4-FSK audio from 162 symbols.
    private func synthesize(_ symbols: [Int]) -> [Float] {
        let sampleRate = WSPRProtocol.sampleRate
        let symbolSamples = WSPRProtocol.symbolSamples
        let totalSamples = WSPRProtocol.frameSamples
        let rampSamples = Int(rampDuration * sampleRate)

        var samples = [Float](repeating: 0, count: totalSamples)
        var phase: Double = 0

        for (symIdx, symbol) in symbols.enumerated() {
            let freq = baseFrequency + Double(symbol) * WSPRProtocol.toneSpacing
            let phaseIncrement = 2.0 * .pi * freq / sampleRate

            for j in 0..<symbolSamples {
                let sampleIdx = symIdx * symbolSamples + j
                guard sampleIdx < totalSamples else { break }

                let value = sin(phase) * amplitude
                samples[sampleIdx] = Float(value)
                phase += phaseIncrement

                if phase >= 2.0 * .pi { phase -= 2.0 * .pi }
            }
        }

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

    /// Duration of generated audio in seconds.
    var frameDuration: Double { WSPRProtocol.frameDuration }
}
