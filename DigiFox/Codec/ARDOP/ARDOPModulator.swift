import Foundation
import Accelerate

/// ARDOP Modulator — TX chain.
///
/// Generates ARDOP frames as audio samples at 12 kHz. Supports all bandwidth
/// modes (200/500/1000/2000 Hz) and modulation types (4FSK, DQPSK, D8PSK, 16QAM).
///
/// TX pipeline: Data → RS encode → CRC-16 append → symbol mapping
///            → leader + frame-type header + OFDM multi-carrier synthesis.
///
/// Reference: https://github.com/pflarue/ardop
final class ARDOPModulator {

    /// Amplitude (0.0–1.0)
    var amplitude: Double = 0.5

    private let rs4  = ARDOPReedSolomon(nsym: 4)
    private let rs8  = ARDOPReedSolomon(nsym: 8)
    private let rs12 = ARDOPReedSolomon(nsym: 12)
    private let rs16 = ARDOPReedSolomon(nsym: 16)

    // MARK: - Public API

    /// Modulate a complete ARDOP frame: leader + frame-type header + data payload.
    /// - Parameters:
    ///   - data: Raw data bytes to transmit
    ///   - frameType: The ARDOP frame type to use
    /// - Returns: Audio samples at 12 kHz
    func modulate(data: [UInt8], frameType: ARDOPFrameType) -> [Float] {
        var samples = [Float]()

        // 1. Leader (two-tone AGC/sync)
        samples.append(contentsOf: generateLeader())

        // 2. Frame type header (2-carrier 50-baud 4FSK)
        samples.append(contentsOf: generateFrameTypeHeader(frameType))

        // 3. Data payload
        if frameType.isData {
            let encoded = rsEncode(data, frameType: frameType)
            let withCRC = ARDOPCRC.append(to: encoded)
            let symbols = dataToSymbols(withCRC, frameType: frameType)
            samples.append(contentsOf: synthesizeData(symbols, frameType: frameType))
        }

        // 4. Raised-cosine ramp at start/end
        applyRamp(&samples)

        return samples
    }

    /// Generate a control frame (no data payload).
    func modulateControl(_ frameType: ARDOPFrameType) -> [Float] {
        var samples = [Float]()
        samples.append(contentsOf: generateLeader())
        samples.append(contentsOf: generateFrameTypeHeader(frameType))
        applyRamp(&samples)
        return samples
    }

    // MARK: - Leader Generation

    /// Two-tone leader for AGC settling and synchronization.
    private func generateLeader() -> [Float] {
        let sr = ARDOPProtocol.sampleRate
        let n = ARDOPProtocol.leaderToneSamples
        var samples = [Float](repeating: 0, count: n * 2)

        // Tone 1
        for i in 0..<n {
            let phase = 2.0 * .pi * ARDOPProtocol.leaderTone1 * Double(i) / sr
            samples[i] = Float(sin(phase) * amplitude)
        }
        // Tone 2
        for i in 0..<n {
            let phase = 2.0 * .pi * ARDOPProtocol.leaderTone2 * Double(i) / sr
            samples[n + i] = Float(sin(phase) * amplitude)
        }

        return samples
    }

    // MARK: - Frame Type Header

    /// Encode frame type byte as 2-carrier 50-baud 4FSK, repeated once.
    private func generateFrameTypeHeader(_ frameType: ARDOPFrameType) -> [Float] {
        let byte = frameType.rawValue

        // 4 symbols from the byte (2 bits each, MSB first)
        var symbols = [Int]()
        for i in stride(from: 6, through: 0, by: -2) {
            symbols.append(Int((byte >> i) & 0x03))
        }
        // Repeat for reliability
        symbols.append(contentsOf: symbols)

        let sr = ARDOPProtocol.sampleRate
        let symSamples = ARDOPProtocol.frameTypeSymbolSamples
        let spacing = ARDOPProtocol.frameTypeToneSpacing
        let carrier1 = ARDOPProtocol.frameTypeCarrier1
        let carrier2 = ARDOPProtocol.frameTypeCarrier2
        let totalSamples = symSamples * symbols.count

        var samples = [Float](repeating: 0, count: totalSamples)
        var phase1 = 0.0
        var phase2 = 0.0

        for (symIdx, symbol) in symbols.enumerated() {
            // Each carrier transmits the same symbol as 4FSK
            let toneOffset = (Double(symbol) - 1.5) * spacing
            let freq1 = carrier1 + toneOffset
            let freq2 = carrier2 + toneOffset
            let inc1 = 2.0 * .pi * freq1 / sr
            let inc2 = 2.0 * .pi * freq2 / sr

            for j in 0..<symSamples {
                let idx = symIdx * symSamples + j
                let s = (sin(phase1) + sin(phase2)) * amplitude * 0.5
                samples[idx] = Float(s)
                phase1 += inc1
                phase2 += inc2
            }
            phase1 = phase1.truncatingRemainder(dividingBy: 2.0 * .pi)
            phase2 = phase2.truncatingRemainder(dividingBy: 2.0 * .pi)
        }

        return samples
    }

    // MARK: - Reed-Solomon Encoding

    private func rsEncode(_ data: [UInt8], frameType: ARDOPFrameType) -> [UInt8] {
        let rs: ARDOPReedSolomon
        switch frameType.rsParitySymbols {
        case 4:  rs = rs4
        case 8:  rs = rs8
        case 12: rs = rs12
        default: rs = rs16
        }
        return rs.encode(data)
    }

    // MARK: - Symbol Mapping

    /// Convert data bytes to modulation symbols.
    private func dataToSymbols(_ data: [UInt8], frameType: ARDOPFrameType) -> [[Int]] {
        let bps = frameType.bitsPerSymbol
        let symbolsPerCarrier = frameType.dataSymbolsPerCarrier
        let carrierCount = frameType.carrierCount

        // Convert bytes to bit stream
        var bits = [Int]()
        for byte in data {
            for i in stride(from: 7, through: 0, by: -1) {
                bits.append(Int((byte >> i) & 1))
            }
        }

        // Pad to required length
        let totalBits = symbolsPerCarrier * carrierCount * bps
        while bits.count < totalBits {
            bits.append(0)
        }

        // Group bits into symbols per carrier
        var carrierSymbols = [[Int]](repeating: [], count: carrierCount)
        var bitIdx = 0
        for sym in 0..<symbolsPerCarrier {
            for carrier in 0..<carrierCount {
                var symbol = 0
                for _ in 0..<bps {
                    symbol = (symbol << 1) | (bitIdx < bits.count ? bits[bitIdx] : 0)
                    bitIdx += 1
                }
                carrierSymbols[carrier].append(symbol)
            }
        }

        return carrierSymbols
    }

    // MARK: - Data Synthesis

    /// Synthesize multi-carrier audio from symbol arrays.
    private func synthesizeData(_ carrierSymbols: [[Int]], frameType: ARDOPFrameType) -> [Float] {
        let sr = ARDOPProtocol.sampleRate
        let symSamples = frameType.symbolSamples
        let symbolsPerCarrier = frameType.dataSymbolsPerCarrier
        let carriers = frameType.carriers
        let totalSamples = symSamples * symbolsPerCarrier

        var samples = [Float](repeating: 0, count: totalSamples)
        let carrierAmplitude = amplitude / Double(carriers.count)

        switch frameType.modulation {
        case .fsk4:
            synthesizeFSK(&samples, carrierSymbols: carrierSymbols, carriers: carriers,
                          symbolRate: frameType.symbolRate, symSamples: symSamples,
                          symbolCount: symbolsPerCarrier, sr: sr, amp: carrierAmplitude)
        case .psk4:
            synthesizePSK(&samples, carrierSymbols: carrierSymbols, carriers: carriers,
                          phases: ARDOPProtocol.psk4Phases, symSamples: symSamples,
                          symbolCount: symbolsPerCarrier, sr: sr, amp: carrierAmplitude)
        case .psk8:
            synthesizePSK(&samples, carrierSymbols: carrierSymbols, carriers: carriers,
                          phases: ARDOPProtocol.psk8Phases, symSamples: symSamples,
                          symbolCount: symbolsPerCarrier, sr: sr, amp: carrierAmplitude)
        case .qam16:
            synthesizeQAM(&samples, carrierSymbols: carrierSymbols, carriers: carriers,
                          symSamples: symSamples, symbolCount: symbolsPerCarrier,
                          sr: sr, amp: carrierAmplitude)
        }

        return samples
    }

    // MARK: - 4FSK Synthesis

    private func synthesizeFSK(_ samples: inout [Float], carrierSymbols: [[Int]],
                                carriers: [Double], symbolRate: Double,
                                symSamples: Int, symbolCount: Int,
                                sr: Double, amp: Double) {
        let toneSpacing = ARDOPProtocol.fskToneSpacing(for: symbolRate)
        let totalSamples = samples.count

        // Per-carrier buffers to avoid concurrent += on shared array
        let bufPtr = UnsafeMutablePointer<[Float]>.allocate(capacity: carriers.count)
        bufPtr.initialize(repeating: [Float](repeating: 0, count: totalSamples), count: carriers.count)
        defer { bufPtr.deinitialize(count: carriers.count); bufPtr.deallocate() }

        DispatchQueue.concurrentPerform(iterations: carriers.count) { cIdx in
            let carrier = carriers[cIdx]
            let symbols = carrierSymbols[cIdx]
            var phase = 0.0

            for symIdx in 0..<symbolCount {
                let symbol = symIdx < symbols.count ? symbols[symIdx] : 0
                let toneOffset = (Double(symbol) - 1.5) * toneSpacing
                let freq = carrier + toneOffset
                let phaseInc = 2.0 * .pi * freq / sr

                for j in 0..<symSamples {
                    let idx = symIdx * symSamples + j
                    guard idx < totalSamples else { break }
                    bufPtr[cIdx][idx] = Float(sin(phase) * amp)
                    phase += phaseInc
                }
                phase = phase.truncatingRemainder(dividingBy: 2.0 * .pi)
            }
        }

        // Sum all carrier buffers into samples
        for cIdx in 0..<carriers.count {
            vDSP_vadd(samples, 1, bufPtr[cIdx], 1, &samples, 1, vDSP_Length(totalSamples))
        }
    }

    // MARK: - Differential PSK Synthesis

    private func synthesizePSK(_ samples: inout [Float], carrierSymbols: [[Int]],
                                carriers: [Double], phases: [Double],
                                symSamples: Int, symbolCount: Int,
                                sr: Double, amp: Double) {
        let totalSamples = samples.count

        let bufPtr = UnsafeMutablePointer<[Float]>.allocate(capacity: carriers.count)
        bufPtr.initialize(repeating: [Float](repeating: 0, count: totalSamples), count: carriers.count)
        defer { bufPtr.deinitialize(count: carriers.count); bufPtr.deallocate() }

        DispatchQueue.concurrentPerform(iterations: carriers.count) { cIdx in
            let carrier = carriers[cIdx]
            var carrierPhase = 0.0
            var prevSymbolPhase = 0.0
            let symbols = carrierSymbols[cIdx]

            for symIdx in 0..<symbolCount {
                let symbol = symIdx < symbols.count ? symbols[symIdx] : 0
                let deltaPhase = symbol < phases.count ? phases[symbol] : 0.0
                let symbolPhase = prevSymbolPhase + deltaPhase
                prevSymbolPhase = symbolPhase

                let phaseInc = 2.0 * .pi * carrier / sr

                for j in 0..<symSamples {
                    let idx = symIdx * symSamples + j
                    guard idx < totalSamples else { break }
                    bufPtr[cIdx][idx] = Float(sin(carrierPhase + symbolPhase) * amp)
                    carrierPhase += phaseInc
                }
                carrierPhase = carrierPhase.truncatingRemainder(dividingBy: 2.0 * .pi)
            }
        }

        for cIdx in 0..<carriers.count {
            vDSP_vadd(samples, 1, bufPtr[cIdx], 1, &samples, 1, vDSP_Length(totalSamples))
        }
    }

    // MARK: - 16QAM Synthesis

    private func synthesizeQAM(_ samples: inout [Float], carrierSymbols: [[Int]],
                                carriers: [Double], symSamples: Int,
                                symbolCount: Int, sr: Double, amp: Double) {
        let constellation = ARDOPProtocol.qam16Points
        let totalSamples = samples.count

        let bufPtr = UnsafeMutablePointer<[Float]>.allocate(capacity: carriers.count)
        bufPtr.initialize(repeating: [Float](repeating: 0, count: totalSamples), count: carriers.count)
        defer { bufPtr.deinitialize(count: carriers.count); bufPtr.deallocate() }

        DispatchQueue.concurrentPerform(iterations: carriers.count) { cIdx in
            let carrier = carriers[cIdx]
            var carrierPhase = 0.0
            let symbols = carrierSymbols[cIdx]
            let phaseInc = 2.0 * .pi * carrier / sr

            for symIdx in 0..<symbolCount {
                let symbol = symIdx < symbols.count ? symbols[symIdx] : 0
                let (iComp, qComp) = symbol < constellation.count
                    ? constellation[symbol] : (0.0, 0.0)

                for j in 0..<symSamples {
                    let idx = symIdx * symSamples + j
                    guard idx < totalSamples else { break }
                    let s = iComp * cos(carrierPhase) - qComp * sin(carrierPhase)
                    bufPtr[cIdx][idx] = Float(s * amp)
                    carrierPhase += phaseInc
                }
                carrierPhase = carrierPhase.truncatingRemainder(dividingBy: 2.0 * .pi)
            }
        }

        for cIdx in 0..<carriers.count {
            vDSP_vadd(samples, 1, bufPtr[cIdx], 1, &samples, 1, vDSP_Length(totalSamples))
        }
    }

    // MARK: - Ramp

    /// Apply raised-cosine ramp to avoid click artifacts.
    private func applyRamp(_ samples: inout [Float]) {
        let rampLen = ARDOPProtocol.rampSamples
        let count = samples.count
        guard rampLen > 0, count > 2 * rampLen else { return }

        for i in 0..<rampLen {
            let ramp = Float(0.5 * (1.0 - cos(.pi * Double(i) / Double(rampLen))))
            samples[i] *= ramp
            samples[count - 1 - i] *= ramp
        }
    }

    // MARK: - Utility

    /// Estimated frame duration in seconds for a given frame type.
    func frameDuration(for frameType: ARDOPFrameType) -> Double {
        let leaderSec = ARDOPProtocol.leaderTotalDurationMs / 1000.0
        let headerSec = Double(ARDOPProtocol.frameTypeSymbolCount * ARDOPProtocol.frameTypeSymbolSamples)
                        / ARDOPProtocol.sampleRate
        let dataSec = frameType.isData
            ? Double(frameType.dataSymbolsPerCarrier * frameType.symbolSamples) / ARDOPProtocol.sampleRate
            : 0.0
        return leaderSec + headerSec + dataSec
    }
}
