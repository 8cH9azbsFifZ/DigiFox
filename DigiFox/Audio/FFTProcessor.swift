import Foundation
import Accelerate

class FFTProcessor {
    let size: Int
    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup
    private var window: [Float]

    init(size: Int = 4096) {
        self.size = size
        self.log2n = vDSP_Length(log2(Double(size)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            fatalError("FFTProcessor: Failed to create FFT setup for size \(size)")
        }
        self.fftSetup = setup
        self.window = [Float](repeating: 0, count: size)
        vDSP_hann_window(&self.window, vDSP_Length(size), Int32(vDSP_HANN_NORM))
    }

    deinit { vDSP_destroy_fftsetup(fftSetup) }

    func magnitudeSpectrum(_ input: [Float]) -> [Float] {
        var windowed = [Float](repeating: 0, count: size)
        let count = min(input.count, size)
        vDSP_vmul(input, 1, window, 1, &windowed, 1, vDSP_Length(count))

        let halfN = size / 2
        var real = [Float](repeating: 0, count: halfN)
        var imag = [Float](repeating: 0, count: halfN)

        real.withUnsafeMutableBufferPointer { realBuf in
            imag.withUnsafeMutableBufferPointer { imagBuf in
                windowed.withUnsafeBufferPointer { buf in
                    buf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { complexBuf in
                        var split = DSPSplitComplex(realp: realBuf.baseAddress!, imagp: imagBuf.baseAddress!)
                        vDSP_ctoz(complexBuf, 2, &split, 1, vDSP_Length(halfN))
                    }
                }
            }
        }

        var split = DSPSplitComplex(realp: &real, imagp: &imag)
        vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))

        var magnitudes = [Float](repeating: 0, count: halfN)
        vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(halfN))

        var scaled = [Float](repeating: 0, count: halfN)
        var scale: Float = 1.0 / Float(size)
        vDSP_vsmul(&magnitudes, 1, &scale, &scaled, 1, vDSP_Length(halfN))

        // Avoid log(0)
        var floored = [Float](repeating: 0, count: halfN)
        var floor: Float = 1e-10
        vDSP_vsadd(&scaled, 1, &floor, &floored, 1, vDSP_Length(halfN))

        var ref: Float = 1.0
        var db = [Float](repeating: 0, count: halfN)
        vDSP_vdbcon(&floored, 1, &ref, &db, 1, vDSP_Length(halfN), 1)
        return db
    }

    func spectrogram(_ samples: [Float], hopSize: Int) -> [[Float]] {
        let count = max(0, (samples.count - size) / hopSize + 1)
        guard count > 0 else { return [] }

        let resultPtr = UnsafeMutablePointer<[Float]>.allocate(capacity: count)
        resultPtr.initialize(repeating: [Float](), count: count)
        defer { resultPtr.deinitialize(count: count); resultPtr.deallocate() }

        DispatchQueue.concurrentPerform(iterations: count) { i in
            let offset = i * hopSize
            resultPtr[i] = self.magnitudeSpectrum(Array(samples[offset..<(offset + self.size)]))
        }
        return (0..<count).map { resultPtr[$0] }
    }
}
