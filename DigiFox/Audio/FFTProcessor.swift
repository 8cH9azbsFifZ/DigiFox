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
        for i in 0..<count { windowed[i] = input[i] * window[i] }

        let halfN = size / 2
        var real = [Float](repeating: 0, count: halfN)
        var imag = [Float](repeating: 0, count: halfN)
        for i in 0..<halfN { real[i] = windowed[2 * i]; imag[i] = windowed[2 * i + 1] }

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
        var result = [[Float]]()
        var offset = 0
        while offset + size <= samples.count {
            result.append(magnitudeSpectrum(Array(samples[offset..<(offset + size)])))
            offset += hopSize
        }
        return result
    }
}
