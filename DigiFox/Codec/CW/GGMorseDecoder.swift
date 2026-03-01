import Foundation

/// Swift wrapper around ggmorse (ggerganov/ggmorse) C++ library.
/// Automatic pitch and speed detection, 5-55 WPM, 200-1200 Hz.
final class GGMorseDecoder {
    private var instance: OpaquePointer?
    private let outputBuffer = UnsafeMutablePointer<CChar>.allocate(capacity: 2048)
    private(set) var sampleRate: Float

    /// Estimated pitch frequency in Hz (auto-detected)
    var pitch: Float {
        guard let inst = instance else { return 0 }
        return ggmorse_wrapper_get_pitch(inst)
    }

    /// Estimated speed in WPM (auto-detected)
    var wpm: Float {
        guard let inst = instance else { return 0 }
        return ggmorse_wrapper_get_speed(inst)
    }

    /// Create a ggmorse decoder.
    /// - Parameters:
    ///   - sampleRate: Audio sample rate (e.g. 12000 for TruSDX, 48000 for USB)
    ///   - samplesPerFrame: Processing frame size (default 128)
    init(sampleRate: Float = 12000, samplesPerFrame: Int = 128) {
        self.sampleRate = sampleRate
        instance = ggmorse_wrapper_create(sampleRate, Int32(samplesPerFrame))
        print("[GGMorse] created: sr=\(sampleRate) spf=\(samplesPerFrame)")
    }

    deinit {
        if let inst = instance { ggmorse_wrapper_destroy(inst) }
        outputBuffer.deallocate()
    }

    /// Process audio samples and return decoded CW text (if any).
    /// - Parameter samples: Mono float samples in [-1, 1]
    /// - Returns: Decoded text string (empty if nothing decoded yet)
    func process(samples: [Float]) -> String {
        guard let inst = instance, !samples.isEmpty else { return "" }
        let n = samples.withUnsafeBufferPointer { buf -> Int32 in
            ggmorse_wrapper_process(inst, buf.baseAddress, Int32(samples.count),
                                    outputBuffer, 2048)
        }
        guard n > 0 else { return "" }
        return String(cString: outputBuffer)
    }

    /// Reset decoder state (e.g. when switching bands)
    func reset() {
        guard let inst = instance else { return }
        ggmorse_wrapper_reset(inst)
        print("[GGMorse] reset")
    }

    /// Recreate decoder with new sample rate
    func updateSampleRate(_ newRate: Float) {
        guard newRate != sampleRate, newRate > 0 else { return }
        print("[GGMorse] rate change: \(sampleRate) → \(newRate)")
        if let inst = instance { ggmorse_wrapper_destroy(inst) }
        sampleRate = newRate
        instance = ggmorse_wrapper_create(newRate, 128)
    }
}
