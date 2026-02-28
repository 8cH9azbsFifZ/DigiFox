import Foundation
import Accelerate

/// Costas array synchronization for FT8.
///
/// Searches a spectrogram for the three Costas sync patterns located at
/// symbol positions [0‥6], [36‥42], and [72‥78] within a 79-symbol frame.
/// Returns candidate (time-offset, frequency-offset, correlation-score) tuples.
enum FT8CostasSync {

    /// A detected candidate with time and frequency offsets plus correlation score.
    struct Candidate: Comparable {
        let timeOffset: Int          // sample offset into the audio buffer
        let freqBin: Int             // FFT bin offset (base frequency)
        let freqHz: Double           // estimated frequency in Hz
        let score: Double            // correlation score (higher = better)

        static func < (lhs: Candidate, rhs: Candidate) -> Bool {
            lhs.score < rhs.score
        }
    }

    // MARK: - Correlation

    /// Search `spectrogram` for Costas sync patterns across a range of time and frequency offsets.
    ///
    /// - Parameters:
    ///   - spectrogram: 2D power spectrum [timeSlice][freqBin]. Each row is one symbol period.
    ///   - freqBins: number of frequency bins per time slice
    ///   - minFreq: minimum search frequency bin
    ///   - maxFreq: maximum search frequency bin
    ///   - maxCandidates: maximum number of candidates to return
    /// - Returns: Array of `Candidate` sorted by descending score.
    static func correlate(
        spectrogram: [[Float]],
        freqBins: Int,
        minFreq: Int = 0,
        maxFreq: Int? = nil,
        maxCandidates: Int = 50
    ) -> [Candidate] {
        let costas = FT8Protocol.costas
        let symbolCount = FT8Protocol.symbolCount
        let maxF = maxFreq ?? (freqBins - 8)
        let maxTime = spectrogram.count - symbolCount

        guard maxTime >= 0, maxF > minFreq else { return [] }

        // Sync block offsets within the 79-symbol frame
        let syncOffsets = [0, 36, 72]

        var candidates = [Candidate]()

        for t in 0...maxTime {
            for f in minFreq..<maxF {
                var score: Double = 0
                var energy: Double = 0

                for offset in syncOffsets {
                    for (i, tone) in costas.enumerated() {
                        let row = t + offset + i
                        guard row < spectrogram.count else { continue }
                        let bin = f + tone
                        guard bin < freqBins else { continue }

                        let signalPower = Double(spectrogram[row][bin])
                        score += signalPower

                        // Compute noise estimate from non-signal bins
                        for b in 0..<8 where b != tone {
                            let nb = f + b
                            if nb < freqBins {
                                energy += Double(spectrogram[row][nb])
                            }
                        }
                    }
                }

                // Normalize: signal / (noise + epsilon)
                let noiseAvg = energy / Double(3 * 7 * 7 + 1)
                let normalized = score / (noiseAvg + 1e-10)

                if normalized > 4.0 {  // threshold
                    let freqHz = Double(f) * FT8Protocol.toneSpacing
                    candidates.append(Candidate(
                        timeOffset: t * FT8Protocol.symbolSamples,
                        freqBin: f,
                        freqHz: freqHz,
                        score: normalized
                    ))
                }
            }
        }

        // Sort descending by score, return top candidates
        candidates.sort(by: >)
        return Array(candidates.prefix(maxCandidates))
    }

    // MARK: - Spectrogram Generation

    /// Generate a spectrogram from audio samples suitable for Costas correlation.
    ///
    /// - Parameters:
    ///   - samples: audio samples at 12000 Hz sample rate
    ///   - fftSize: FFT window size (default: symbol period = 1920)
    /// - Returns: 2D array [timeSlice][freqBin] of power magnitudes
    static func spectrogram(from samples: [Float], fftSize: Int = FT8Protocol.symbolSamples) -> [[Float]] {
        let hop = fftSize  // non-overlapping windows aligned to symbol boundaries
        let numSlices = (samples.count - fftSize) / hop + 1
        let halfFFT = fftSize / 2

        guard numSlices > 0 else { return [] }

        let log2n = vDSP_Length(log2(Double(fftSize)))
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return []
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        // Hann window
        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

        var result = [[Float]]()
        result.reserveCapacity(numSlices)

        var real = [Float](repeating: 0, count: halfFFT)
        var imag = [Float](repeating: 0, count: halfFFT)

        for slice in 0..<numSlices {
            let offset = slice * hop
            guard offset + fftSize <= samples.count else { break }

            // Apply window
            var windowed = [Float](repeating: 0, count: fftSize)
            vDSP_vmul(Array(samples[offset..<(offset + fftSize)]), 1,
                      window, 1, &windowed, 1, vDSP_Length(fftSize))

            // Pack for FFT & compute
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

            // Magnitude squared
            var magnitudes = [Float](repeating: 0, count: halfFFT)
            real.withUnsafeMutableBufferPointer { realBuf in
                imag.withUnsafeMutableBufferPointer { imagBuf in
                    var split = DSPSplitComplex(realp: realBuf.baseAddress!, imagp: imagBuf.baseAddress!)
                    vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(halfFFT))
                }
            }

            // Convert to dB scale
            var one: Float = 1e-10
            vDSP_vsadd(magnitudes, 1, &one, &magnitudes, 1, vDSP_Length(halfFFT))

            result.append(magnitudes)
        }

        return result
    }

    // MARK: - Fine Frequency Estimation

    /// Refine frequency estimate using parabolic interpolation on the sync peak.
    static func refineFrequency(spectrogram: [[Float]], candidate: Candidate, freqBins: Int) -> Double {
        let costas = FT8Protocol.costas
        let f = candidate.freqBin

        guard f > 0, f + 7 < freqBins else { return candidate.freqHz }

        var sumOffset: Double = 0
        var count = 0
        let syncOffsets = [0, 36, 72]
        let t = candidate.timeOffset / FT8Protocol.symbolSamples

        for offset in syncOffsets {
            for (i, tone) in costas.enumerated() {
                let row = t + offset + i
                guard row < spectrogram.count else { continue }
                let bin = f + tone
                guard bin > 0, bin + 1 < freqBins else { continue }

                let left  = Double(spectrogram[row][bin - 1])
                let center = Double(spectrogram[row][bin])
                let right = Double(spectrogram[row][bin + 1])

                let denom = 2.0 * (2.0 * center - left - right)
                if abs(denom) > 1e-10 {
                    sumOffset += (right - left) / denom
                    count += 1
                }
            }
        }

        let avgOffset = count > 0 ? sumOffset / Double(count) : 0
        return (Double(f) + avgOffset) * FT8Protocol.toneSpacing
    }
}
