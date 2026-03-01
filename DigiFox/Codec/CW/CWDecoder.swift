import Foundation

// =============================================================
// OLD CW DECODER — DISABLED, replaced by GGMorseDecoder
// To re-enable: remove #if false, re-add cw_decoder.h to bridging header
// =============================================================
#if false

/// Swift wrapper around cw-decoder-core C library.
/// Processes audio samples and returns decoded CW text.
final class CWDecoder {
    private var decoder: OpaquePointer?
    private let outputBuffer = UnsafeMutablePointer<CChar>.allocate(capacity: 1024)

    /// Current estimated WPM
    var wpm: Float {
        guard let dec = decoder else { return 0 }
        return cw_decoder_get_wpm(dec)
    }

    /// Create a CW decoder with given parameters
    init(sampleRate: Int = 48000, centerFreq: Float = 700.0, bandwidth: Float = 400.0, initialWPM: Float = 20.0) {
        var cfg = cw_config_t()
        cw_config_init(&cfg)
        cfg.sample_rate = Int32(sampleRate)
        cfg.center_freq = centerFreq
        cfg.bandwidth = bandwidth
        cfg.initial_wpm = initialWPM
        cfg.min_wpm = 5.0
        cfg.max_wpm = 60.0
        cfg.timing_mode = CW_TIMING_KALMAN
        cfg.envelope_mode = CW_ENVELOPE_MULTIPASS
        cfg.min_word_length = 1
        decoder = cw_decoder_create(&cfg)
        print("[CWDecoder] created: sr=\(sampleRate) center=\(centerFreq) bw=\(bandwidth) wpm=\(initialWPM)")
    }

    deinit {
        if let dec = decoder { cw_decoder_destroy(dec) }
        outputBuffer.deallocate()
    }

    /// Process audio samples and return decoded text (if any).
    /// Audio should be mono float samples in [-1, 1] range.
    func process(samples: [Float]) -> String {
        guard let dec = decoder, !samples.isEmpty else { return "" }
        let n = samples.withUnsafeBufferPointer { buf -> Int32 in
            cw_decoder_process(dec, buf.baseAddress, Int32(samples.count),
                               outputBuffer, 1024)
        }
        guard n > 0 else { return "" }
        return String(bytes: UnsafeBufferPointer(start: outputBuffer, count: Int(n))
                        .map { UInt8(bitPattern: $0) }, encoding: .ascii) ?? ""
    }

    /// Flush remaining buffered text (call when stopping)
    func finalize() -> String {
        guard let dec = decoder else { return "" }
        let n = cw_decoder_finalize(dec, outputBuffer, 1024)
        guard n > 0 else { return "" }
        return String(bytes: UnsafeBufferPointer(start: outputBuffer, count: Int(n))
                        .map { UInt8(bitPattern: $0) }, encoding: .ascii) ?? ""
    }

    /// Reset decoder state for reuse
    func reset() {
        guard let dec = decoder else { return }
        cw_decoder_reset(dec)
    }
}

#endif // disabled old CW decoder
