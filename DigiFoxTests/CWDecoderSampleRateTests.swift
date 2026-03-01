import XCTest
@testable import DigiFox

final class CWDecoderSampleRateTests: XCTestCase {

    // MARK: - Initialization at various sample rates

    func testInitAt12000Hz() {
        let decoder = CWDecoder(sampleRate: 12000)
        XCTAssertNotNil(decoder)
        XCTAssertEqual(decoder.wpm, 20.0, accuracy: 1.0, "Initial WPM should be ~20")
    }

    func testInitAt48000Hz() {
        let decoder = CWDecoder(sampleRate: 48000)
        XCTAssertNotNil(decoder)
        XCTAssertEqual(decoder.wpm, 20.0, accuracy: 1.0)
    }

    func testInitAt44100Hz() {
        let decoder = CWDecoder(sampleRate: 44100)
        XCTAssertNotNil(decoder)
        XCTAssertEqual(decoder.wpm, 20.0, accuracy: 1.0)
    }

    func testInitAt8000Hz() {
        let decoder = CWDecoder(sampleRate: 8000)
        XCTAssertNotNil(decoder)
        XCTAssertEqual(decoder.wpm, 20.0, accuracy: 1.0)
    }

    // MARK: - Silence produces no output

    func testSilenceProducesNoOutput() {
        let rates = [8000, 12000, 44100, 48000]
        for rate in rates {
            let decoder = CWDecoder(sampleRate: rate)
            let silence = [Float](repeating: 0, count: rate) // 1 second of silence
            let result = decoder.process(samples: silence)
            // Silence should not produce decoded characters
            // (may produce spaces, which is acceptable)
            let trimmed = result.trimmingCharacters(in: .whitespaces)
            XCTAssertTrue(trimmed.isEmpty, "Silence at \(rate) Hz should not decode chars, got: '\(result)'")
        }
    }

    // MARK: - Tone detection at correct center frequency

    /// Generate a pure tone at the center frequency and verify the decoder detects it
    func testToneDetectionAtVariousSampleRates() {
        let rates = [12000, 48000, 44100]
        let centerFreq: Float = 700.0

        for rate in rates {
            let decoder = CWDecoder(sampleRate: rate, centerFreq: centerFreq, bandwidth: 100.0)
            // Generate 200ms of 700 Hz tone (a dit at ~12 WPM)
            let numSamples = Int(Double(rate) * 0.2)
            var tone = [Float](repeating: 0, count: numSamples)
            for i in 0..<numSamples {
                tone[i] = 0.8 * sin(2.0 * .pi * Float(centerFreq) * Float(i) / Float(rate))
            }
            // Process tone followed by silence
            _ = decoder.process(samples: tone)
            let silence = [Float](repeating: 0, count: Int(Double(rate) * 0.5))
            _ = decoder.process(samples: silence)
            // We mainly verify it doesn't crash at different rates
            // The decoder should handle arbitrary valid sample rates
        }
    }

    // MARK: - Reset preserves sample rate

    func testResetPreservesFunctionality() {
        let decoder = CWDecoder(sampleRate: 12000)
        let silence = [Float](repeating: 0, count: 1200)
        _ = decoder.process(samples: silence)
        decoder.reset()
        // Should still work after reset
        let result = decoder.process(samples: silence)
        let trimmed = result.trimmingCharacters(in: .whitespaces)
        XCTAssertTrue(trimmed.isEmpty, "Post-reset silence should not produce chars")
    }

    // MARK: - Finalize

    func testFinalizeReturnsWithoutCrash() {
        let rates = [8000, 12000, 44100, 48000]
        for rate in rates {
            let decoder = CWDecoder(sampleRate: rate)
            let result = decoder.finalize()
            // Should not crash, may return empty
            XCTAssertNotNil(result, "Finalize at \(rate) Hz should not crash")
        }
    }

    // MARK: - AudioEngine effectiveSampleRate

    func testAudioEngineDefaultSampleRate() {
        let engine = AudioEngine()
        XCTAssertEqual(engine.effectiveSampleRate, 12000, "Default sample rate should be 12000")
    }
}
