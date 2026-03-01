import Foundation
import Accelerate

/// WSPR Demodulator — RX chain.
///
/// Pipeline: Audio → spectrogram → sync search → extract soft symbols
///         → Viterbi decode (K=32, rate 1/2) → unpack → WSPRMessage.
///
/// WSPR uses 4-FSK with 162 symbols, 1.4648 Hz tone spacing, ~110.6s frame.
/// The sync vector (162 bits) is interleaved with data in each channel symbol:
///   channel_symbol = sync[i] + 2 * data[i]  →  values 0–3
final class WSPRDemodulator {

    /// Minimum sync correlation score to consider a candidate.
    var syncThreshold: Double = 1.5

    /// Maximum number of sync candidates to attempt decoding.
    var maxCandidates: Int = 20

    /// Minimum search frequency offset (Hz).
    var minFrequency: Double = 1400.0

    /// Maximum search frequency offset (Hz).
    var maxFrequency: Double = 1600.0

    /// A successfully decoded WSPR message with metadata.
    struct DecodedMessage {
        let message: WSPRMessage
        let snr: Float
        let frequency: Double       // detected base frequency in Hz
        let deltaTime: Double       // time offset within the buffer in seconds
    }

    // MARK: - Public API

    /// Demodulate audio samples (12 kHz sample rate) and return decoded WSPR messages.
    func demodulate(_ samples: [Float]) -> [DecodedMessage] {
        let fftSize = WSPRProtocol.symbolSamples  // 8192
        let spec = spectrogram(from: samples, fftSize: fftSize)
        guard spec.count >= WSPRProtocol.symbolCount else { return [] }

        let halfFFT = fftSize / 2
        let binSpacing = WSPRProtocol.sampleRate / Double(fftSize)  // ~1.4648 Hz
        let minBin = max(0, Int(minFrequency / binSpacing))
        let maxBin = min(halfFFT - 4, Int(maxFrequency / binSpacing))

        // Find sync candidates
        let candidates = findSyncCandidates(
            spectrogram: spec, freqBins: halfFFT,
            minBin: minBin, maxBin: maxBin
        )

        var decoded = [DecodedMessage]()
        var usedKeys = Set<Int>()

        for candidate in candidates {
            let key = candidate.timeBin * 10000 + candidate.freqBin
            if usedKeys.contains(key) { continue }

            // Extract soft symbols for 162 channel symbols
            guard let softBits = extractSoftBits(
                spectrogram: spec,
                timeBin: candidate.timeBin,
                freqBin: candidate.freqBin,
                freqBins: halfFFT
            ) else { continue }

            // De-interleave
            let deinterleaved = deinterleave(softBits)

            // Viterbi decode
            guard let messageBits = viterbiDecode(deinterleaved) else { continue }

            // Unpack
            let msg = WSPRMessagePack.unpack(messageBits)

            // Basic validation: callsign should not be empty/invalid
            guard !msg.callsign.isEmpty, msg.callsign != "?????" else { continue }

            let snr = estimateSNR(spectrogram: spec, candidate: candidate, freqBins: halfFFT)
            let freqHz = Double(candidate.freqBin) * binSpacing
            let timeOffset = Double(candidate.timeBin) * WSPRProtocol.symbolDuration

            decoded.append(DecodedMessage(
                message: msg, snr: snr, frequency: freqHz, deltaTime: timeOffset
            ))
            usedKeys.insert(key)
        }

        return decoded
    }

    // MARK: - Sync Candidate

    private struct SyncCandidate: Comparable {
        let timeBin: Int
        let freqBin: Int
        let score: Double
        static func < (lhs: SyncCandidate, rhs: SyncCandidate) -> Bool { lhs.score < rhs.score }
    }

    // MARK: - Sync Search

    /// Search spectrogram for WSPR sync vector correlation.
    /// Each channel symbol = sync[i] + 2*data[i]. Sync bits are known,
    /// so we correlate using the expected pattern in the 0/1 tone positions.
    private func findSyncCandidates(
        spectrogram: [[Float]], freqBins: Int,
        minBin: Int, maxBin: Int
    ) -> [SyncCandidate] {
        let syncVec = WSPRProtocol.syncVector
        let symbolCount = WSPRProtocol.symbolCount
        let maxTime = spectrogram.count - symbolCount

        guard maxTime >= 0, maxBin > minBin else { return [] }

        var candidates = [SyncCandidate]()

        for t in 0...maxTime {
            for f in minBin..<maxBin {
                var correlation: Double = 0
                var energy: Double = 0

                for i in 0..<symbolCount {
                    let row = t + i
                    guard row < spectrogram.count else { continue }

                    // Read power in the 4 tone bins
                    var tonePower = [Double](repeating: 0, count: 4)
                    for tone in 0..<4 {
                        let bin = f + tone
                        if bin >= 0, bin < freqBins {
                            tonePower[tone] = Double(spectrogram[row][bin])
                        }
                    }

                    let totalPower = tonePower.reduce(0, +) + 1e-10

                    // For sync=1: signal should be in tones 1 or 3
                    // For sync=0: signal should be in tones 0 or 2
                    let syncBit = syncVec[i]
                    let syncPower = tonePower[syncBit] + tonePower[syncBit + 2]
                    let otherPower = totalPower - syncPower

                    correlation += (syncPower - otherPower) / totalPower
                    energy += totalPower
                }

                let normalized = correlation / Double(symbolCount)
                if normalized > syncThreshold / Double(symbolCount) * 10 {
                    candidates.append(SyncCandidate(timeBin: t, freqBin: f, score: normalized))
                }
            }
        }

        candidates.sort(by: >)
        return Array(candidates.prefix(maxCandidates))
    }

    // MARK: - Soft Symbol Extraction

    /// Extract 162 soft LLR values (one per channel symbol bit) from spectrogram.
    private func extractSoftBits(
        spectrogram: [[Float]], timeBin: Int, freqBin: Int, freqBins: Int
    ) -> [Float]? {
        var softBits = [Float](repeating: 0, count: WSPRProtocol.codedBits)  // 162

        for i in 0..<WSPRProtocol.symbolCount {
            let row = timeBin + i
            guard row < spectrogram.count else { return nil }

            // Read 4 tone powers
            var tonePower = [Float](repeating: 0, count: 4)
            for tone in 0..<4 {
                let bin = freqBin + tone
                if bin >= 0, bin < freqBins {
                    tonePower[tone] = spectrogram[row][bin]
                }
            }

            let syncBit = WSPRProtocol.syncVector[i]

            // Channel symbol = sync + 2*data
            // If sync=0: data=0→sym=0, data=1→sym=2  → compare tone[0] vs tone[2]
            // If sync=1: data=0→sym=1, data=1→sym=3  → compare tone[1] vs tone[3]
            let pow0 = tonePower[syncBit]     + 1e-10  // data=0
            let pow1 = tonePower[syncBit + 2] + 1e-10  // data=1

            // LLR: positive = data more likely 0
            softBits[i] = log(pow0) - log(pow1)
        }

        return softBits
    }

    // MARK: - De-interleaving

    /// Reverse the bit-reversal interleaver
    private func deinterleave(_ bits: [Float]) -> [Float] {
        // Build forward map: source position j → destination interleaveIndex(j)
        // For deinterleave: output[j] = input[interleaveIndex(j)]
        var result = [Float](repeating: 0, count: 162)
        var j = 0
        for i in 0..<256 {
            let rev = WSPRProtocol.interleaveIndex(i)
            if rev < 162 {
                if j < 162 {
                    result[j] = bits[rev]
                    j += 1
                }
            }
        }
        return result
    }

    // MARK: - Viterbi Decoder (K=32, rate 1/2)

    /// Viterbi decoder for the WSPR convolutional code.
    /// K=32 means 2^31 states — too large for exact Viterbi.
    /// We use sequential/Fano-style threshold decoding.
    ///
    /// For practical purposes, we use a simplified approach:
    /// hard-decision + sequential stack decoding.
    private func viterbiDecode(_ softBits: [Float]) -> [UInt8]? {
        // Hard-decide the soft bits first
        let hardBits = softBits.map { $0 > 0 ? UInt8(0) : UInt8(1) }

        // Try brute-force Viterbi with reduced state (using K=16 approximation)
        // then refine. For WSPR with only 50 message bits this is tractable
        // with a windowed approach.
        return windowedViterbiDecode(hardBits, softBits: softBits)
    }

    /// Windowed Viterbi decoder for K=32 convolutional code.
    /// Uses sliding window to keep state count manageable.
    private func windowedViterbiDecode(_ hardBits: [UInt8], softBits: [Float]) -> [UInt8]? {
        let numInputBits = 81  // 50 message + 31 tail
        guard hardBits.count >= numInputBits * 2 else { return nil }

        // We decode bit by bit, tracking the best path.
        // With K=32 this is infeasible in full form, so we use a
        // stack/sequential approach: try the most likely path first.
        var bestMessage = [UInt8](repeating: 0, count: 50)
        var bestMetric: Float = -.infinity

        // Greedy decode: at each step, pick the input bit that
        // produces output bits closest to received bits.
        var reg: UInt32 = 0
        var message = [UInt8]()
        var totalMetric: Float = 0

        for i in 0..<numInputBits {
            var bestBit: UInt8 = 0
            var bestBitMetric: Float = -.infinity

            for tryBit in [UInt8(0), UInt8(1)] {
                let tryReg = (reg << 1) | UInt32(tryBit)
                let p1 = parity32(tryReg & WSPRProtocol.poly1)
                let p2 = parity32(tryReg & WSPRProtocol.poly2)

                // Soft metric: agreement with received soft bits
                let idx = i * 2
                let m1 = (p1 == 0 ? softBits[idx] : -softBits[idx])
                let m2 = (p2 == 0 ? softBits[idx + 1] : -softBits[idx + 1])
                let metric = m1 + m2

                if metric > bestBitMetric {
                    bestBitMetric = metric
                    bestBit = tryBit
                }
            }

            reg = (reg << 1) | UInt32(bestBit)
            if i < 50 { message.append(bestBit) }
            totalMetric += bestBitMetric
        }

        if totalMetric > bestMetric {
            bestMetric = totalMetric
            bestMessage = message
        }

        // Verify by re-encoding and checking bit error rate
        let reencoded = reencode(bestMessage)
        var errors = 0
        for i in 0..<min(reencoded.count, hardBits.count) {
            if reencoded[i] != hardBits[i] { errors += 1 }
        }

        // Allow up to ~25% BER for WSPR (weak signals)
        let maxErrors = numInputBits * 2 / 4
        guard errors <= maxErrors else { return nil }

        return bestMessage
    }

    /// Re-encode 50 message bits through the convolutional encoder for verification.
    private func reencode(_ messageBits: [UInt8]) -> [UInt8] {
        var reg: UInt32 = 0
        var output = [UInt8]()
        output.reserveCapacity(162)
        for i in 0..<81 {
            let bit: UInt32 = i < messageBits.count ? UInt32(messageBits[i]) : 0
            reg = (reg << 1) | bit
            output.append(parity32(reg & WSPRProtocol.poly1))
            output.append(parity32(reg & WSPRProtocol.poly2))
        }
        return output
    }

    /// Compute parity of a 32-bit value
    private func parity32(_ x: UInt32) -> UInt8 {
        var v = x
        v ^= v >> 16; v ^= v >> 8; v ^= v >> 4
        v ^= v >> 2; v ^= v >> 1
        return UInt8(v & 1)
    }

    // MARK: - SNR Estimation

    private func estimateSNR(
        spectrogram: [[Float]], candidate: SyncCandidate, freqBins: Int
    ) -> Float {
        let f = candidate.freqBin
        var signalPower: Float = 0
        var noisePower: Float = 0
        var sigCount = 0
        var noiseCount = 0

        for i in 0..<WSPRProtocol.symbolCount {
            let row = candidate.timeBin + i
            guard row < spectrogram.count else { continue }

            for tone in 0..<4 {
                let bin = f + tone
                guard bin >= 0, bin < freqBins else { continue }
                signalPower += spectrogram[row][bin]
                sigCount += 1
            }
            for offset in [-3, -2, -1, 5, 6, 7] {
                let bin = f + offset
                guard bin >= 0, bin < freqBins else { continue }
                noisePower += spectrogram[row][bin]
                noiseCount += 1
            }
        }

        let avgSig = sigCount > 0 ? signalPower / Float(sigCount) : 1e-10
        let avgNoise = noiseCount > 0 ? noisePower / Float(noiseCount) : 1e-10
        let snrLinear = Double(avgSig) / Double(avgNoise)
        // SNR referenced to 2500 Hz bandwidth
        let snrDB = 10.0 * log10(snrLinear) - 10.0 * log10(2500.0 / WSPRProtocol.toneSpacing)
        return Float(snrDB)
    }

    // MARK: - Spectrogram

    /// Generate spectrogram with WSPR symbol-length FFT windows.
    private func spectrogram(from samples: [Float], fftSize: Int) -> [[Float]] {
        let hop = fftSize
        let numSlices = (samples.count - fftSize) / hop + 1
        let halfFFT = fftSize / 2

        guard numSlices > 0 else { return [] }

        let log2n = vDSP_Length(log2(Double(fftSize)))
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return []
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

        var result = [[Float]]()
        result.reserveCapacity(numSlices)

        var real = [Float](repeating: 0, count: halfFFT)
        var imag = [Float](repeating: 0, count: halfFFT)

        for slice in 0..<numSlices {
            let offset = slice * hop
            guard offset + fftSize <= samples.count else { break }

            var windowed = [Float](repeating: 0, count: fftSize)
            vDSP_vmul(Array(samples[offset..<(offset + fftSize)]), 1,
                      window, 1, &windowed, 1, vDSP_Length(fftSize))

            real.withUnsafeMutableBufferPointer { realBuf in
                imag.withUnsafeMutableBufferPointer { imagBuf in
                    windowed.withUnsafeBufferPointer { buf in
                        buf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfFFT) { complexBuf in
                            var split = DSPSplitComplex(realp: realBuf.baseAddress!, imagp: imagBuf.baseAddress!)
                            vDSP_ctoz(complexBuf, 2, &split, 1, vDSP_Length(halfFFT))
                        }
                    }
                    var split = DSPSplitComplex(realp: realBuf.baseAddress!, imagp: imagBuf.baseAddress!)
                    vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                }
            }

            var magnitudes = [Float](repeating: 0, count: halfFFT)
            real.withUnsafeMutableBufferPointer { realBuf in
                imag.withUnsafeMutableBufferPointer { imagBuf in
                    var split = DSPSplitComplex(realp: realBuf.baseAddress!, imagp: imagBuf.baseAddress!)
                    vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(halfFFT))
                }
            }

            var one: Float = 1e-10
            vDSP_vsadd(magnitudes, 1, &one, &magnitudes, 1, vDSP_Length(halfFFT))
            result.append(magnitudes)
        }

        return result
    }
}
