import Foundation
import Accelerate

/// ARDOP Demodulator — RX chain.
///
/// Receives audio samples at 12 kHz and detects/decodes ARDOP frames.
/// Supports all bandwidth modes and modulation types.
///
/// RX pipeline: Audio → leader detection → frame-type decode
///            → multi-carrier demodulation → RS decode → CRC validate.
///
/// Reference: https://github.com/pflarue/ardop
final class ARDOPDemodulator {

    /// Minimum leader correlation threshold (0.0–1.0)
    var leaderThreshold: Double = 0.6

    /// Maximum frequency search range (Hz)
    var minFrequency: Double = 200.0
    var maxFrequency: Double = 3000.0

    private let rs4  = ARDOPReedSolomon(nsym: 4)
    private let rs8  = ARDOPReedSolomon(nsym: 8)
    private let rs12 = ARDOPReedSolomon(nsym: 12)
    private let rs16 = ARDOPReedSolomon(nsym: 16)

    /// Result of a successful ARDOP frame decode
    struct DecodedFrame {
        let frameType: ARDOPFrameType
        let data: [UInt8]
        let snr: Float
        let timeOffset: Double
    }

    // MARK: - Public API

    /// Demodulate audio samples and return any decoded ARDOP frames.
    func demodulate(_ samples: [Float]) -> [DecodedFrame] {
        let leaderPositions = detectLeaders(in: samples)
        guard !leaderPositions.isEmpty else { return [] }

        // Parallel frame decoding (each leader position is independent)
        let lock = NSLock()
        var decoded = [DecodedFrame]()
        DispatchQueue.concurrentPerform(iterations: leaderPositions.count) { idx in
            let position = leaderPositions[idx]
            guard let result = self.decodeFrame(from: samples, at: position) else { return }
            lock.lock()
            decoded.append(result)
            lock.unlock()
        }

        return decoded
    }

    // MARK: - Leader Detection

    /// Detect two-tone leaders in the audio stream using Goertzel algorithm.
    private func detectLeaders(in samples: [Float]) -> [Int] {
        let sr = ARDOPProtocol.sampleRate
        let toneSamples = ARDOPProtocol.leaderToneSamples
        let windowSize = toneSamples
        let stepSize = windowSize / 4
        var positions = [Int]()

        let f1 = ARDOPProtocol.leaderTone1
        let f2 = ARDOPProtocol.leaderTone2

        var offset = 0
        while offset + toneSamples * 2 < samples.count {
            // Check for tone 1 in first window
            let power1 = goertzelPower(samples, offset: offset, length: toneSamples, frequency: f1, sampleRate: sr)
            let noise1 = averagePower(samples, offset: offset, length: toneSamples)

            // Check for tone 2 in second window
            let power2 = goertzelPower(samples, offset: offset + toneSamples, length: toneSamples,
                                       frequency: f2, sampleRate: sr)
            let noise2 = averagePower(samples, offset: offset + toneSamples, length: toneSamples)

            let snr1 = noise1 > 0 ? power1 / noise1 : 0
            let snr2 = noise2 > 0 ? power2 / noise2 : 0

            if snr1 > leaderThreshold * 10 && snr2 > leaderThreshold * 10 {
                positions.append(offset + toneSamples * 2)
                offset += toneSamples * 2 + ARDOPProtocol.frameTypeSymbolSamples * ARDOPProtocol.frameTypeSymbolCount
            } else {
                offset += stepSize
            }
        }

        return positions
    }

    // MARK: - Frame Decode

    /// Attempt to decode a complete frame starting after the leader.
    private func decodeFrame(from samples: [Float], at headerStart: Int) -> DecodedFrame? {
        // Decode frame type header
        guard let frameType = decodeFrameType(from: samples, at: headerStart) else { return nil }

        let headerSamples = ARDOPProtocol.frameTypeSymbolSamples * ARDOPProtocol.frameTypeSymbolCount
        let dataStart = headerStart + headerSamples

        // Control frames have no data payload
        if frameType.isControl {
            let snr = estimateSNR(samples, at: headerStart - ARDOPProtocol.leaderTotalSamples)
            return DecodedFrame(
                frameType: frameType, data: [],
                snr: snr,
                timeOffset: Double(headerStart) / ARDOPProtocol.sampleRate
            )
        }

        // Demodulate data payload
        let dataSamples = frameType.dataSymbolsPerCarrier * frameType.symbolSamples
        guard dataStart + dataSamples <= samples.count else { return nil }

        let dataSlice = Array(samples[dataStart..<(dataStart + dataSamples)])
        let symbols = demodulateData(dataSlice, frameType: frameType)
        let bytes = symbolsToBytes(symbols, frameType: frameType)

        // Validate CRC
        guard ARDOPCRC.validate(bytes) else { return nil }
        let dataWithoutCRC = Array(bytes.dropLast(2))

        // RS decode
        guard let corrected = rsDecode(dataWithoutCRC, frameType: frameType) else { return nil }

        let snr = estimateSNR(samples, at: headerStart - ARDOPProtocol.leaderTotalSamples)
        return DecodedFrame(
            frameType: frameType,
            data: corrected,
            snr: snr,
            timeOffset: Double(headerStart) / ARDOPProtocol.sampleRate
        )
    }

    // MARK: - Frame Type Decoding

    /// Decode frame type byte from 2-carrier 50-baud 4FSK header.
    private func decodeFrameType(from samples: [Float], at offset: Int) -> ARDOPFrameType? {
        let sr = ARDOPProtocol.sampleRate
        let symSamples = ARDOPProtocol.frameTypeSymbolSamples
        let spacing = ARDOPProtocol.frameTypeToneSpacing
        let carrier = ARDOPProtocol.frameTypeCarrier1

        // Decode 8 symbols (4 original + 4 repeat)
        var allSymbols = [Int]()

        for symIdx in 0..<ARDOPProtocol.frameTypeSymbolCount {
            let start = offset + symIdx * symSamples
            guard start + symSamples <= samples.count else { return nil }
            let slice = Array(samples[start..<(start + symSamples)])

            // Find best-matching tone using Goertzel
            var bestSymbol = 0
            var bestPower = 0.0
            for sym in 0..<4 {
                let toneOffset = (Double(sym) - 1.5) * spacing
                let freq = carrier + toneOffset
                let power = goertzelPower(slice, offset: 0, length: symSamples,
                                          frequency: freq, sampleRate: sr)
                if power > bestPower {
                    bestPower = power
                    bestSymbol = sym
                }
            }
            allSymbols.append(bestSymbol)
        }

        // Majority vote between original (0..3) and repeat (4..7)
        var votedSymbols = [Int]()
        for i in 0..<4 {
            let orig = allSymbols[i]
            let rep = allSymbols[i + 4]
            votedSymbols.append(orig == rep ? orig : orig)  // prefer original on disagreement
        }

        // Reconstruct byte from 4 symbols (2 bits each, MSB first)
        var byte: UInt8 = 0
        for sym in votedSymbols {
            byte = (byte << 2) | UInt8(sym & 0x03)
        }

        return ARDOPFrameType(rawValue: byte)
    }

    // MARK: - Data Demodulation

    /// Demodulate multi-carrier data symbols from audio samples.
    private func demodulateData(_ samples: [Float], frameType: ARDOPFrameType) -> [[Int]] {
        switch frameType.modulation {
        case .fsk4:
            return demodulateFSK(samples, frameType: frameType)
        case .psk4:
            return demodulatePSK(samples, frameType: frameType, phases: ARDOPProtocol.psk4Phases)
        case .psk8:
            return demodulatePSK(samples, frameType: frameType, phases: ARDOPProtocol.psk8Phases)
        case .qam16:
            return demodulateQAM(samples, frameType: frameType)
        }
    }

    // MARK: - 4FSK Demodulation

    private func demodulateFSK(_ samples: [Float], frameType: ARDOPFrameType) -> [[Int]] {
        let sr = ARDOPProtocol.sampleRate
        let symSamples = frameType.symbolSamples
        let carriers = frameType.carriers
        let toneSpacing = ARDOPProtocol.fskToneSpacing(for: frameType.symbolRate)
        let symbolCount = frameType.dataSymbolsPerCarrier

        // Parallel per-carrier demodulation
        let resultPtr = UnsafeMutablePointer<[Int]>.allocate(capacity: carriers.count)
        resultPtr.initialize(repeating: [Int](), count: carriers.count)
        defer { resultPtr.deinitialize(count: carriers.count); resultPtr.deallocate() }

        DispatchQueue.concurrentPerform(iterations: carriers.count) { cIdx in
            let carrier = carriers[cIdx]
            var symbols = [Int]()
            symbols.reserveCapacity(symbolCount)

            for symIdx in 0..<symbolCount {
                let start = symIdx * symSamples
                guard start + symSamples <= samples.count else { break }
                let slice = Array(samples[start..<(start + symSamples)])

                var bestSym = 0
                var bestPower = 0.0
                for sym in 0..<4 {
                    let toneOffset = (Double(sym) - 1.5) * toneSpacing
                    let freq = carrier + toneOffset
                    let power = self.goertzelPower(slice, offset: 0, length: symSamples,
                                                   frequency: freq, sampleRate: sr)
                    if power > bestPower {
                        bestPower = power
                        bestSym = sym
                    }
                }
                symbols.append(bestSym)
            }
            resultPtr[cIdx] = symbols
        }

        return (0..<carriers.count).map { resultPtr[$0] }
    }

    // MARK: - PSK Demodulation

    private func demodulatePSK(_ samples: [Float], frameType: ARDOPFrameType,
                                phases: [Double]) -> [[Int]] {
        let sr = ARDOPProtocol.sampleRate
        let symSamples = frameType.symbolSamples
        let carriers = frameType.carriers
        let symbolCount = frameType.dataSymbolsPerCarrier

        // Parallel per-carrier demodulation (prevPhase is per-carrier, no cross-dependency)
        let resultPtr = UnsafeMutablePointer<[Int]>.allocate(capacity: carriers.count)
        resultPtr.initialize(repeating: [Int](), count: carriers.count)
        defer { resultPtr.deinitialize(count: carriers.count); resultPtr.deallocate() }

        DispatchQueue.concurrentPerform(iterations: carriers.count) { cIdx in
            let carrier = carriers[cIdx]
            var prevPhase = 0.0
            var symbols = [Int]()
            symbols.reserveCapacity(symbolCount)

            for symIdx in 0..<symbolCount {
                let start = symIdx * symSamples
                guard start + symSamples <= samples.count else { break }

                var iSum = 0.0, qSum = 0.0
                for j in 0..<symSamples {
                    let t = Double(j) / sr
                    let sample = Double(samples[start + j])
                    iSum += sample * cos(2.0 * .pi * carrier * t)
                    qSum += sample * sin(2.0 * .pi * carrier * t)
                }

                let measuredPhase = atan2(qSum, iSum)
                var deltaPhase = measuredPhase - prevPhase
                while deltaPhase < 0 { deltaPhase += 2.0 * .pi }
                while deltaPhase >= 2.0 * .pi { deltaPhase -= 2.0 * .pi }
                prevPhase = measuredPhase

                var bestSym = 0
                var bestDist = Double.infinity
                for (sym, refPhase) in phases.enumerated() {
                    var dist = abs(deltaPhase - refPhase)
                    if dist > .pi { dist = 2.0 * .pi - dist }
                    if dist < bestDist {
                        bestDist = dist
                        bestSym = sym
                    }
                }
                symbols.append(bestSym)
            }
            resultPtr[cIdx] = symbols
        }

        return (0..<carriers.count).map { resultPtr[$0] }
    }

    // MARK: - 16QAM Demodulation

    private func demodulateQAM(_ samples: [Float], frameType: ARDOPFrameType) -> [[Int]] {
        let sr = ARDOPProtocol.sampleRate
        let symSamples = frameType.symbolSamples
        let carriers = frameType.carriers
        let symbolCount = frameType.dataSymbolsPerCarrier
        let constellation = ARDOPProtocol.qam16Points

        // Parallel per-carrier demodulation
        let resultPtr = UnsafeMutablePointer<[Int]>.allocate(capacity: carriers.count)
        resultPtr.initialize(repeating: [Int](), count: carriers.count)
        defer { resultPtr.deinitialize(count: carriers.count); resultPtr.deallocate() }

        DispatchQueue.concurrentPerform(iterations: carriers.count) { cIdx in
            let carrier = carriers[cIdx]
            var symbols = [Int]()
            symbols.reserveCapacity(symbolCount)

            for symIdx in 0..<symbolCount {
                let start = symIdx * symSamples
                guard start + symSamples <= samples.count else { break }

                var iSum = 0.0, qSum = 0.0
                for j in 0..<symSamples {
                    let t = Double(j) / sr
                    let sample = Double(samples[start + j])
                    iSum += sample * cos(2.0 * .pi * carrier * t)
                    qSum += sample * -sin(2.0 * .pi * carrier * t)
                }
                let scale = 2.0 / Double(symSamples)
                let iVal = iSum * scale
                let qVal = qSum * scale

                var bestSym = 0
                var bestDist = Double.infinity
                for (sym, point) in constellation.enumerated() {
                    let dist = (iVal - point.0) * (iVal - point.0) + (qVal - point.1) * (qVal - point.1)
                    if dist < bestDist {
                        bestDist = dist
                        bestSym = sym
                    }
                }
                symbols.append(bestSym)
            }
            resultPtr[cIdx] = symbols
        }

        return (0..<carriers.count).map { resultPtr[$0] }
    }

    // MARK: - Symbol to Byte Conversion

    /// Convert demodulated carrier symbols back to bytes.
    private func symbolsToBytes(_ carrierSymbols: [[Int]], frameType: ARDOPFrameType) -> [UInt8] {
        let bps = frameType.bitsPerSymbol
        let symbolCount = frameType.dataSymbolsPerCarrier
        let carrierCount = frameType.carrierCount

        // Reconstruct bit stream (interleaved by carrier, matching modulator order)
        var bits = [Int]()
        for sym in 0..<symbolCount {
            for carrier in 0..<carrierCount {
                let symbol = (carrier < carrierSymbols.count && sym < carrierSymbols[carrier].count)
                    ? carrierSymbols[carrier][sym] : 0
                for i in stride(from: bps - 1, through: 0, by: -1) {
                    bits.append((symbol >> i) & 1)
                }
            }
        }

        // Pack bits into bytes
        var bytes = [UInt8]()
        for i in stride(from: 0, to: bits.count - 7, by: 8) {
            var byte: UInt8 = 0
            for j in 0..<8 {
                byte = (byte << 1) | UInt8(bits[i + j])
            }
            bytes.append(byte)
        }

        return bytes
    }

    // MARK: - Reed-Solomon Decoding

    private func rsDecode(_ data: [UInt8], frameType: ARDOPFrameType) -> [UInt8]? {
        let rs: ARDOPReedSolomon
        switch frameType.rsParitySymbols {
        case 4:  rs = rs4
        case 8:  rs = rs8
        case 12: rs = rs12
        default: rs = rs16
        }
        return rs.decode(data)
    }

    // MARK: - Signal Analysis

    /// Goertzel algorithm: compute power at a single frequency bin.
    private func goertzelPower(_ samples: [Float], offset: Int, length: Int,
                                frequency: Double, sampleRate: Double) -> Double {
        let k = Int(0.5 + Double(length) * frequency / sampleRate)
        let w = 2.0 * .pi * Double(k) / Double(length)
        let coeff = Float(2.0 * cos(w))

        var s0: Float = 0, s1: Float = 0, s2: Float = 0
        let end = min(offset + length, samples.count)
        for i in offset..<end {
            s0 = samples[i] + coeff * s1 - s2
            s2 = s1
            s1 = s0
        }

        return Double(s1 * s1 + s2 * s2 - coeff * s1 * s2)
    }

    /// Average power of a sample window using Accelerate.
    private func averagePower(_ samples: [Float], offset: Int, length: Int) -> Double {
        let end = min(offset + length, samples.count)
        let count = end - offset
        guard count > 0 else { return 0 }
        var sumSq: Float = 0
        vDSP_svesq(Array(samples[offset..<end]), 1, &sumSq, vDSP_Length(count))
        return Double(sumSq) / Double(count)
    }

    /// Estimate SNR at a given position.
    private func estimateSNR(_ samples: [Float], at offset: Int) -> Float {
        let windowSize = ARDOPProtocol.leaderToneSamples
        guard offset >= 0, offset + windowSize <= samples.count else { return 0 }

        let signalPower = goertzelPower(samples, offset: offset, length: windowSize,
                                         frequency: ARDOPProtocol.leaderTone1,
                                         sampleRate: ARDOPProtocol.sampleRate)
        let noisePower = averagePower(samples, offset: offset, length: windowSize)

        guard noisePower > 0 else { return 0 }
        return Float(10.0 * log10(signalPower / noisePower))
    }
}
