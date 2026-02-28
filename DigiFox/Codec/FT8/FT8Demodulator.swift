import Foundation
import Accelerate

/// FT8 Demodulator — RX chain.
///
/// Pipeline: Audio → spectrogram → Costas sync search → extract soft symbols
///         → LDPC decode → CRC-14 validate → unpack → FT8Message.
final class FT8Demodulator {

    /// Minimum Costas correlation score to consider a candidate.
    var syncThreshold: Double = 4.0

    /// Maximum number of sync candidates to attempt decoding.
    var maxCandidates: Int = 40

    /// Minimum search frequency (Hz).
    var minFrequency: Double = 200.0

    /// Maximum search frequency (Hz).
    var maxFrequency: Double = 3000.0

    /// A successfully decoded FT8 message with metadata.
    struct DecodedMessage {
        let message: FT8Message
        let snr: Float              // estimated signal-to-noise ratio in dB
        let frequency: Double       // detected base frequency in Hz
        let timeOffset: Double      // time offset within the buffer in seconds
    }

    // MARK: - Public API

    /// Demodulate audio samples (12 kHz sample rate) and return decoded FT8 messages.
    func demodulate(_ samples: [Float]) -> [DecodedMessage] {
        // Generate spectrogram
        let spec = FT8CostasSync.spectrogram(from: samples)
        guard !spec.isEmpty else { return [] }

        let freqBins = spec[0].count
        let binSpacing = FT8Protocol.sampleRate / Double(FT8Protocol.symbolSamples * 2)
        let minBin = max(0, Int(minFrequency / binSpacing))
        let maxBin = min(freqBins - 8, Int(maxFrequency / binSpacing))

        // Find sync candidates
        let candidates = FT8CostasSync.correlate(
            spectrogram: spec,
            freqBins: freqBins,
            minFreq: minBin,
            maxFreq: maxBin,
            maxCandidates: maxCandidates
        )

        var decoded = [DecodedMessage]()
        var usedOffsets = Set<Int>()   // prevent duplicate decodes at same time/freq

        for candidate in candidates {
            // Deduplicate: skip if we already decoded near this time/freq
            let key = (candidate.timeOffset / FT8Protocol.symbolSamples) * 1000 + candidate.freqBin
            if usedOffsets.contains(key) { continue }

            // Extract soft symbols
            let symbolStart = candidate.timeOffset / FT8Protocol.symbolSamples
            guard let softBits = extractSoftBits(
                spectrogram: spec,
                timeStart: symbolStart,
                freqBin: candidate.freqBin,
                freqBins: freqBins
            ) else { continue }

            // LDPC decode
            guard let decoded91 = LDPC.decode(softBits) else { continue }

            // CRC validate
            let message91 = decoded91.map { $0 }
            guard FT8CRC.validate(message91) else { continue }

            // Extract 77 payload bits
            let payload = Array(message91[0..<FT8Protocol.payloadBits])

            // Unpack message
            let msg = FT8MessagePack.unpack(payload)

            // Estimate SNR
            let snr = estimateSNR(spectrogram: spec, candidate: candidate, freqBins: freqBins)

            // Refine frequency
            let refinedFreq = FT8CostasSync.refineFrequency(
                spectrogram: spec, candidate: candidate, freqBins: freqBins
            )

            let timeOffsetSec = Double(candidate.timeOffset) / FT8Protocol.sampleRate

            decoded.append(DecodedMessage(
                message: msg,
                snr: snr,
                frequency: refinedFreq,
                timeOffset: timeOffsetSec
            ))

            usedOffsets.insert(key)
        }

        return decoded
    }

    // MARK: - Soft Symbol Extraction

    /// Extract 174 soft LLR values from the spectrogram at the given time/freq position.
    private func extractSoftBits(
        spectrogram: [[Float]],
        timeStart: Int,
        freqBin: Int,
        freqBins: Int
    ) -> [Float]? {
        let dataPositions = FT8Protocol.dataPositions
        guard dataPositions.count == FT8Protocol.dataSymbolCount else { return nil }

        var llr = [Float](repeating: 0, count: FT8Protocol.codedBits)

        for (dataIdx, symPos) in dataPositions.enumerated() {
            let row = timeStart + symPos
            guard row >= 0, row < spectrogram.count else { return nil }

            // Read power in each of the 8 tone bins
            var tonePower = [Float](repeating: 0, count: 8)
            for tone in 0..<8 {
                let bin = freqBin + tone
                if bin >= 0, bin < freqBins {
                    tonePower[tone] = spectrogram[row][bin]
                }
            }

            // Convert tone powers to soft bits (3 bits per symbol, Gray-coded)
            let bitOffset = dataIdx * FT8Protocol.bitsPerSymbol
            let softBits = toneToSoftBits(tonePower)
            for b in 0..<FT8Protocol.bitsPerSymbol {
                if bitOffset + b < llr.count {
                    llr[bitOffset + b] = softBits[b]
                }
            }
        }

        return llr
    }

    /// Convert 8 tone powers to 3 soft LLR bits using Gray-code mapping.
    ///
    /// For each of the 3 bit positions, compute the LLR as:
    ///   LLR(bit_k) = log(sum of powers where bit_k=0) - log(sum of powers where bit_k=1)
    /// Positive LLR means bit is more likely 0.
    private func toneToSoftBits(_ powers: [Float]) -> [Float] {
        var softBits = [Float](repeating: 0, count: 3)

        for bit in 0..<3 {
            var sum0: Float = 1e-10
            var sum1: Float = 1e-10

            for tone in 0..<8 {
                let grayVal = FT8Protocol.grayDecode[tone]
                let bitVal = (grayVal >> (2 - bit)) & 1
                if bitVal == 0 {
                    sum0 += powers[tone]
                } else {
                    sum1 += powers[tone]
                }
            }

            softBits[bit] = log(sum0) - log(sum1)
        }

        return softBits
    }

    // MARK: - SNR Estimation

    /// Estimate signal-to-noise ratio from the spectrogram around a candidate.
    private func estimateSNR(
        spectrogram: [[Float]],
        candidate: FT8CostasSync.Candidate,
        freqBins: Int
    ) -> Float {
        let timeStart = candidate.timeOffset / FT8Protocol.symbolSamples
        let f = candidate.freqBin

        var signalPower: Float = 0
        var noisePower: Float = 0
        var signalCount = 0
        var noiseCount = 0

        for pos in FT8Protocol.dataPositions {
            let row = timeStart + pos
            guard row >= 0, row < spectrogram.count else { continue }

            // Signal: max power in tone bins
            for tone in 0..<8 {
                let bin = f + tone
                guard bin >= 0, bin < freqBins else { continue }
                signalPower += spectrogram[row][bin]
                signalCount += 1
            }

            // Noise: bins outside the signal bandwidth
            for offset in [-4, -3, -2, -1, 9, 10, 11, 12] {
                let bin = f + offset
                guard bin >= 0, bin < freqBins else { continue }
                noisePower += spectrogram[row][bin]
                noiseCount += 1
            }
        }

        let avgSignal = signalCount > 0 ? signalPower / Float(signalCount) : 1e-10
        let avgNoise = noiseCount > 0 ? noisePower / Float(noiseCount) : 1e-10

        // SNR in dB, referenced to 2500 Hz bandwidth
        let snrLinear = Double(avgSignal) / Double(avgNoise)
        let snrDB = 10.0 * log10(snrLinear) - 10.0 * log10(2500.0 / FT8Protocol.toneSpacing)

        return Float(snrDB)
    }
}
