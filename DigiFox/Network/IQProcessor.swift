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

    /// USB demodulation: extract upper sideband audio from complex IQ.
    /// FFT → zero negative frequencies → IFFT → real part.
    /// Properly rejects image signals that would alias into the passband.
    static func iqToAudio(_ iq: [Float]) -> [Float] {
        let count = iq.count / 2
        guard count > 0 else { return [] }

        // Separate I and Q channels
        var real = [Float](repeating: 0, count: count)
        var imag = [Float](repeating: 0, count: count)
        for i in 0..<count {
            real[i] = iq[i * 2]
            imag[i] = iq[i * 2 + 1]
        }

        // Pad to power-of-2 for FFT
        let log2n = vDSP_Length(max(1, Int(log2(Double(count)).rounded(.up))))
        let fftSize = Int(1 << log2n)
        if fftSize > count {
            real.append(contentsOf: [Float](repeating: 0, count: fftSize - count))
            imag.append(contentsOf: [Float](repeating: 0, count: fftSize - count))
        }

        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return Array(real.prefix(count))
        }

        let half = fftSize / 2

        real.withUnsafeMutableBufferPointer { realBuf in
            imag.withUnsafeMutableBufferPointer { imagBuf in
                var split = DSPSplitComplex(realp: realBuf.baseAddress!, imagp: imagBuf.baseAddress!)

                // Forward FFT
                vDSP_fft_zip(fftSetup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))

                // Zero negative frequencies (USB demod: keep DC + positive only)
                for i in (half + 1)..<fftSize {
                    realBuf[i] = 0
                    imagBuf[i] = 0
                }
                // Double positive frequencies (except DC and Nyquist)
                for i in 1..<half {
                    realBuf[i] *= 2
                    imagBuf[i] *= 2
                }

                // Inverse FFT
                vDSP_fft_zip(fftSetup, &split, 1, log2n, FFTDirection(kFFTDirection_Inverse))

                // Scale by 1/N
                var scale = 1.0 / Float(fftSize)
                vDSP_vsmul(realBuf.baseAddress!, 1, &scale, realBuf.baseAddress!, 1, vDSP_Length(fftSize))
            }
        }

        vDSP_destroy_fftsetup(fftSetup)

        // Return real part, trimmed to original length
        return Array(real.prefix(count))
    }

    // MARK: - Anti-alias FIR filter coefficients for 48→12 kHz decimation
    // Low-pass FIR, cutoff ~5.5 kHz at 48 kHz sample rate (order 31)
    private static let antiAliasFilter: [Float] = {
        // Windowed-sinc LPF: cutoff = 5500/48000 = 0.1146, order 31
        let order = 31
        let fc: Float = 5500.0 / 48000.0
        let mid = order / 2
        var h = [Float](repeating: 0, count: order)
        for i in 0..<order {
            let n = Float(i - mid)
            if i == mid {
                h[i] = 2.0 * fc
            } else {
                h[i] = sin(2.0 * .pi * fc * n) / (.pi * n)
            }
            // Hamming window
            h[i] *= 0.54 - 0.46 * cos(2.0 * .pi * Float(i) / Float(order - 1))
        }
        // Normalize
        let sum = h.reduce(0, +)
        return h.map { $0 / sum }
    }()

    /// Decimate audio from source rate to 12 kHz with anti-alias filtering.
    static func decimateTo12kHz(_ input: [Float], from srcRate: Double) -> [Float] {
        guard !input.isEmpty else { return [] }
        let ratio = srcRate / 12000.0
        if abs(ratio - 1.0) < 0.01 { return input }

        // Apply anti-alias low-pass filter before downsampling
        var filtered = [Float](repeating: 0, count: input.count + antiAliasFilter.count - 1)
        vDSP_conv(input, 1, antiAliasFilter, 1, &filtered, 1,
                  vDSP_Length(input.count), vDSP_Length(antiAliasFilter.count))
        // Trim to original length (compensate for filter delay)
        let delay = antiAliasFilter.count / 2
        let trimmed: [Float]
        if input.count > delay {
            trimmed = Array(filtered[delay..<(delay + input.count)])
        } else {
            trimmed = Array(filtered.prefix(input.count))
        }

        // Decimate via interpolation
        let outputCount = Int(Double(trimmed.count) / ratio)
        guard outputCount > 1 else { return trimmed }

        var positions = [Float](repeating: 0, count: outputCount)
        var start: Float = 0
        var step = Float(ratio)
        vDSP_vramp(&start, &step, &positions, 1, vDSP_Length(outputCount))

        var maxPos = Float(trimmed.count - 1)
        var zero: Float = 0
        vDSP_vclip(positions, 1, &zero, &maxPos, &positions, 1, vDSP_Length(outputCount))

        var output = [Float](repeating: 0, count: outputCount)
        vDSP_vlint(trimmed, positions, 1, &output, 1, vDSP_Length(outputCount), vDSP_Length(trimmed.count))
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
        guard n > 0 else { return [] }

        // Use vDSP for FFT-based Hilbert
        let log2n = vDSP_Length(log2(Double(n)).rounded(.up))
        let fftSize = Int(1 << log2n)

        // Zero-pad to power of 2
        var padded = audio48k + [Float](repeating: 0, count: fftSize - n)
        var imagPart = [Float](repeating: 0, count: fftSize)

        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            var result = [Float](repeating: 0, count: n * 2)
            for i in 0..<n { result[i * 2] = audio48k[i] }
            return result
        }

        let half = fftSize / 2

        padded.withUnsafeMutableBufferPointer { realBuf in
            imagPart.withUnsafeMutableBufferPointer { imagBuf in
                var split = DSPSplitComplex(realp: realBuf.baseAddress!, imagp: imagBuf.baseAddress!)

                // Forward FFT
                vDSP_fft_zip(fftSetup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))

                // Zero negative frequencies, double positive (Hilbert envelope)
                for i in (half + 1)..<fftSize {
                    realBuf[i] = 0
                    imagBuf[i] = 0
                }
                for i in 1..<half {
                    realBuf[i] *= 2
                    imagBuf[i] *= 2
                }

                // Inverse FFT
                vDSP_fft_zip(fftSetup, &split, 1, log2n, FFTDirection(kFFTDirection_Inverse))

                // Scale by 1/N (vDSP convention)
                var scale = Float(1.0 / Float(fftSize))
                vDSP_vsmul(realBuf.baseAddress!, 1, &scale, realBuf.baseAddress!, 1, vDSP_Length(fftSize))
                vDSP_vsmul(imagBuf.baseAddress!, 1, &scale, imagBuf.baseAddress!, 1, vDSP_Length(fftSize))
            }
        }

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
