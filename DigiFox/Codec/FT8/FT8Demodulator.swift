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
        guard !spec.isEmpty else {
            Log.d("FT8-Demod", "spectrogram empty!")
            return []
        }

        let freqBins = spec[0].count
        let binSpacing = FT8Protocol.sampleRate / Double(FT8Protocol.symbolSamples * 2)
        let minBin = max(0, Int(minFrequency / binSpacing))
        let maxBin = min(freqBins - 8, Int(maxFrequency / binSpacing))
        Log.d("FT8-Demod", "spectrogram: \(spec.count)×\(freqBins), binSpacing=\(String(format: "%.2f", binSpacing))Hz, search \(minBin)..\(maxBin) bins")

        // Find sync candidates
        let candidates = FT8CostasSync.correlate(
            spectrogram: spec,
            freqBins: freqBins,
            minFreq: minBin,
            maxFreq: maxBin,
            maxCandidates: maxCandidates
        )
        Log.d("FT8-Demod", "\(candidates.count) sync candidates (threshold=\(syncThreshold), top score=\(candidates.first.map { String(format: "%.2f", $0.score) } ?? "n/a"))")

        // Parallel candidate decoding (LDPC is the bottleneck)
        struct IndexedDecode {
            let index: Int
            let key: Int
            let message: DecodedMessage
        }
        let lock = NSLock()
        var parallelResults = [IndexedDecode]()

        let ldpcPassCount = NSLock()
        var ldpcPassed = 0, crcPassed = 0

        DispatchQueue.concurrentPerform(iterations: candidates.count) { idx in
            let candidate = candidates[idx]
            let key = (candidate.timeOffset / FT8Protocol.symbolSamples) * 1000 + candidate.freqBin

            let symbolStart = candidate.timeOffset / FT8Protocol.symbolSamples
            guard let softBits = self.extractSoftBits(
                spectrogram: spec,
                timeStart: symbolStart,
                freqBin: candidate.freqBin,
                freqBins: freqBins
            ) else { return }

            guard let decoded91 = LDPC.decode(softBits) else { return }
            ldpcPassCount.lock(); ldpcPassed += 1; ldpcPassCount.unlock()

            let message91 = decoded91.map { $0 }
            guard FT8CRC.validate(message91) else { return }
            ldpcPassCount.lock(); crcPassed += 1; ldpcPassCount.unlock()

            let payload = Array(message91[0..<FT8Protocol.payloadBits])
            let msg = FT8MessagePack.unpack(payload)
            let snr = self.estimateSNR(spectrogram: spec, candidate: candidate, freqBins: freqBins)
            let refinedFreq = FT8CostasSync.refineFrequency(
                spectrogram: spec, candidate: candidate, freqBins: freqBins
            )
            let timeOffsetSec = Double(candidate.timeOffset) / FT8Protocol.sampleRate

            let result = DecodedMessage(
                message: msg, snr: snr, frequency: refinedFreq, timeOffset: timeOffsetSec
            )
            lock.lock()
            parallelResults.append(IndexedDecode(index: idx, key: key, message: result))
            lock.unlock()
        }
        Log.d("FT8-Demod", "Pipeline: \(candidates.count) candidates → \(ldpcPassed) LDPC pass → \(crcPassed) CRC pass → \(parallelResults.count) unique")

        // Deduplicate preserving priority order (lower index = higher score)
        parallelResults.sort { $0.index < $1.index }
        var decoded = [DecodedMessage]()
        var usedOffsets = Set<Int>()
        for r in parallelResults {
            if !usedOffsets.contains(r.key) {
                decoded.append(r.message)
                usedOffsets.insert(r.key)
            }
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
    /// Uses the same max-log-MAP approach as ft8_lib's ft8_extract_symbol:
    ///   LLR(bit_k) = max(powers where bit_k=0) - max(powers where bit_k=1)
    /// Positive LLR means bit is more likely 0.
    /// Magnitudes are converted to log domain first.
    private func toneToSoftBits(_ powers: [Float]) -> [Float] {
        // Map tone magnitudes via Gray code into natural bit order (log domain)
        var s = [Float](repeating: -120.0, count: 8)
        for j in 0..<8 {
            let p = powers[FT8Protocol.grayEncode[j]]
            s[j] = p > 1e-10 ? 10.0 * log10(p) : -120.0
        }

        // ft8_lib convention (positive = bit 1 more likely):
        //   logl[0] = max4(s[4],s[5],s[6],s[7]) - max4(s[0],s[1],s[2],s[3])
        //   logl[1] = max4(s[2],s[3],s[6],s[7]) - max4(s[0],s[1],s[4],s[5])
        //   logl[2] = max4(s[1],s[3],s[5],s[7]) - max4(s[0],s[2],s[4],s[6])
        // Our convention: positive = bit 0 more likely → negate
        var softBits = [Float](repeating: 0, count: 3)
        softBits[0] = max4(s[0], s[1], s[2], s[3]) - max4(s[4], s[5], s[6], s[7])
        softBits[1] = max4(s[0], s[1], s[4], s[5]) - max4(s[2], s[3], s[6], s[7])
        softBits[2] = max4(s[0], s[2], s[4], s[6]) - max4(s[1], s[3], s[5], s[7])

        return softBits
    }

    private func max4(_ a: Float, _ b: Float, _ c: Float, _ d: Float) -> Float {
        return max(max(a, b), max(c, d))
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
