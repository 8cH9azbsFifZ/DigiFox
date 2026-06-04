import Foundation
import Accelerate
import os.log

private let logger = Logger(subsystem: "com.digifox.app", category: "IQProcessor")

/// HPSDR Protocol 1 packet constants
let kEP6PacketSize = 1032       // 8 + 2*512
let kMetisHeaderSize = 8
let kUSBFrameSize = 512
let kUSBSync: [UInt8] = [0x7F, 0x7F, 0x7F]

/// Processes EP6 IQ data packets from Hermes SDR.
/// Extracts 24-bit I/Q samples, applies IQ swap, normalizes to Float.
struct IQProcessor {
    let numReceivers: Int
    let swapIQ: Bool

    /// Bytes per sample: 6 bytes per receiver (3 I + 3 Q) + 2 mic bytes
    var bytesPerSample: Int { 6 * numReceivers + 2 }

    /// Samples per USB frame
    var samplesPerFrame: Int { (kUSBFrameSize - 8) / bytesPerSample }

    /// Samples per EP6 packet (2 frames)
    var samplesPerPacket: Int { samplesPerFrame * 2 }

    init(numReceivers: Int = 1, swapIQ: Bool = true) {
        self.numReceivers = numReceivers
        self.swapIQ = swapIQ
    }

    /// Parse an EP6 packet and return IQ data as interleaved [I, Q, I, Q, ...] Float arrays.
    /// Returns one array per receiver.
    func parseEP6Packet(_ data: Data) -> [[Float]] {
        guard data.count >= kEP6PacketSize else {
            return Array(repeating: [], count: numReceivers)
        }

        var results = Array(repeating: [Float](), count: numReceivers)
        let bps = bytesPerSample

        for frameOffset in [kMetisHeaderSize, kMetisHeaderSize + kUSBFrameSize] {
            // Check sync bytes
            guard data[frameOffset] == 0x7F,
                  data[frameOffset + 1] == 0x7F,
                  data[frameOffset + 2] == 0x7F else { continue }

            let payloadStart = frameOffset + 8
            let payloadEnd = frameOffset + kUSBFrameSize
            let payloadLen = payloadEnd - payloadStart
            let nSamples = payloadLen / bps

            for sampleIdx in 0..<nSamples {
                let sampleOffset = payloadStart + sampleIdx * bps

                for rx in 0..<numReceivers {
                    let base = sampleOffset + rx * 6

                    // Extract 24-bit signed I value (big-endian)
                    var iVal = Int32(data[base]) << 16 | Int32(data[base + 1]) << 8 | Int32(data[base + 2])
                    if iVal >= 0x800000 { iVal -= 0x1000000 }  // sign extension

                    // Extract 24-bit signed Q value (big-endian)
                    var qVal = Int32(data[base + 3]) << 16 | Int32(data[base + 4]) << 8 | Int32(data[base + 5])
                    if qVal >= 0x800000 { qVal -= 0x1000000 }  // sign extension

                    // Normalize to [-1, 1]
                    let scale: Float = 1.0 / 8388607.0
                    let iFloat = Float(iVal) * scale
                    let qFloat = Float(qVal) * scale

                    // Apply IQ swap (HL2 standard gateware sends bytes as [Q, I])
                    if swapIQ {
                        results[rx].append(qFloat)  // Real = Q byte
                        results[rx].append(iFloat)  // Imag = I byte
                    } else {
                        results[rx].append(iFloat)  // Real = I byte
                        results[rx].append(qFloat)  // Imag = Q byte
                    }
                }
            }
        }
        return results
    }

    /// Extract EP6 status from C0-C4 bytes in USB frame headers.
    /// Returns (PTT active, status register address, C1-C4 data)
    static func parseEP6Status(_ data: Data) -> (ptt: Bool, addr: UInt8, c1c4: [UInt8])? {
        guard data.count >= kEP6PacketSize else { return nil }
        let c0 = data[kMetisHeaderSize + 3]
        let ptt = (c0 & 0x01) != 0
        let addr = (c0 >> 1) & 0x7F
        let c1 = data[kMetisHeaderSize + 4]
        let c2 = data[kMetisHeaderSize + 5]
        let c3 = data[kMetisHeaderSize + 6]
        let c4 = data[kMetisHeaderSize + 7]
        return (ptt, addr, [c1, c2, c3, c4])
    }

    /// Convert interleaved IQ [I, Q, I, Q, ...] to real audio (I channel only).
    /// For HPSDR with NCO at dial frequency, the I channel contains USB audio.
    static func iqToAudio(_ iq: [Float]) -> [Float] {
        // Extract every other sample (I values at even indices)
        let count = iq.count / 2
        var audio = [Float](repeating: 0, count: count)
        for i in 0..<count {
            audio[i] = iq[i * 2]
        }
        return audio
    }

    /// Decimate audio from source rate to 12 kHz using Accelerate.
    static func decimateTo12kHz(_ input: [Float], from srcRate: Double) -> [Float] {
        guard !input.isEmpty else { return [] }
        let ratio = srcRate / 12000.0
        if abs(ratio - 1.0) < 0.01 { return input }
        let outputCount = Int(Double(input.count) / ratio)
        guard outputCount > 1 else { return input }

        var positions = [Float](repeating: 0, count: outputCount)
        var start: Float = 0
        var step = Float(ratio)
        vDSP_vramp(&start, &step, &positions, 1, vDSP_Length(outputCount))

        var maxPos = Float(input.count - 1)
        var zero: Float = 0
        vDSP_vclip(positions, 1, &zero, &maxPos, &positions, 1, vDSP_Length(outputCount))

        var output = [Float](repeating: 0, count: outputCount)
        vDSP_vlint(input, positions, 1, &output, 1, vDSP_Length(outputCount), vDSP_Length(input.count))
        return output
    }

    /// Upsample 12 kHz audio to 48 kHz for TX IQ generation.
    static func upsampleTo48kHz(_ input: [Float]) -> [Float] {
        guard !input.isEmpty else { return [] }
        let ratio: Float = 12000.0 / 48000.0
        let outputCount = input.count * 4

        var positions = [Float](repeating: 0, count: outputCount)
        var start: Float = 0
        var step = ratio
        vDSP_vramp(&start, &step, &positions, 1, vDSP_Length(outputCount))

        var maxPos = Float(input.count - 1)
        var zero: Float = 0
        vDSP_vclip(positions, 1, &zero, &maxPos, &positions, 1, vDSP_Length(outputCount))

        var output = [Float](repeating: 0, count: outputCount)
        vDSP_vlint(input, positions, 1, &output, 1, vDSP_Length(outputCount), vDSP_Length(input.count))
        return output
    }

    /// Convert real audio to IQ (analytic signal via Hilbert transform) for TX.
    /// Output: interleaved [I, Q, I, Q, ...] at 48 kHz.
    static func audioToTxIQ(_ audio12k: [Float]) -> [Float] {
        // 1. Upsample to 48 kHz
        let audio48k = upsampleTo48kHz(audio12k)
        let n = audio48k.count

        // 2. Hilbert transform: Q = Hilbert(I)
        //    Simple approach: FFT → zero negative freqs → IFFT
        //    For our purpose (narrowband FT8/JS8 at 1-3 kHz), a simpler
        //    90° phase shift FIR works, but FFT is more precise.
        guard n > 0 else { return [] }

        // Use vDSP for FFT-based Hilbert
        let log2n = vDSP_Length(log2(Double(n)).rounded(.up))
        let fftSize = Int(1 << log2n)

        // Zero-pad to power of 2
        var padded = audio48k + [Float](repeating: 0, count: fftSize - n)
        var imagPart = [Float](repeating: 0, count: fftSize)

        // Forward FFT
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            // Fallback: return real-only IQ (Q=0)
            var result = [Float](repeating: 0, count: n * 2)
            for i in 0..<n { result[i * 2] = audio48k[i] }
            return result
        }

        var splitComplex = DSPSplitComplex(realp: &padded, imagp: &imagPart)
        vDSP_fft_zip(fftSetup, &splitComplex, 1, log2n, FFTDirection(kFFTDirection_Forward))

        // Zero negative frequencies, double positive (Hilbert envelope)
        let half = fftSize / 2
        for i in (half + 1)..<fftSize {
            padded[i] = 0
            imagPart[i] = 0
        }
        for i in 1..<half {
            padded[i] *= 2
            imagPart[i] *= 2
        }

        // Inverse FFT
        vDSP_fft_zip(fftSetup, &splitComplex, 1, log2n, FFTDirection(kFFTDirection_Inverse))

        // Scale by 1/N (vDSP convention)
        var scale = Float(1.0 / Float(fftSize))
        vDSP_vsmul(padded, 1, &scale, &padded, 1, vDSP_Length(fftSize))
        vDSP_vsmul(imagPart, 1, &scale, &imagPart, 1, vDSP_Length(fftSize))

        vDSP_destroy_fftsetup(fftSetup)

        // Interleave [I, Q, I, Q, ...]  (trim to original length)
        var result = [Float](repeating: 0, count: n * 2)
        for i in 0..<n {
            result[i * 2] = padded[i]        // I = real
            result[i * 2 + 1] = imagPart[i]  // Q = imag (Hilbert of I)
        }
        return result
    }
}
