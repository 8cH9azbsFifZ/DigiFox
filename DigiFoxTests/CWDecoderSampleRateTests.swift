import XCTest
@testable import DigiFox

final class GGMorseDecoderTests: XCTestCase {

    // MARK: - Initialization at various sample rates

    func testInitAt12000Hz() {
        let decoder = GGMorseDecoder(sampleRate: 12000)
        XCTAssertNotNil(decoder)
        XCTAssertEqual(decoder.sampleRate, 12000)
    }

    func testInitAt48000Hz() {
        let decoder = GGMorseDecoder(sampleRate: 48000)
        XCTAssertNotNil(decoder)
        XCTAssertEqual(decoder.sampleRate, 48000)
    }

    func testInitAt44100Hz() {
        let decoder = GGMorseDecoder(sampleRate: 44100)
        XCTAssertNotNil(decoder)
        XCTAssertEqual(decoder.sampleRate, 44100)
    }

    func testInitAt8000Hz() {
        let decoder = GGMorseDecoder(sampleRate: 8000)
        XCTAssertNotNil(decoder)
        XCTAssertEqual(decoder.sampleRate, 8000)
    }

    // MARK: - Silence produces no output

    func testSilenceProducesNoOutput() {
        let rates: [Float] = [8000, 12000, 44100, 48000]
        for rate in rates {
            let decoder = GGMorseDecoder(sampleRate: rate)
            let silence = [Float](repeating: 0, count: Int(rate)) // 1 second of silence
            let result = decoder.process(samples: silence)
            let trimmed = result.trimmingCharacters(in: .whitespaces)
            XCTAssertTrue(trimmed.isEmpty, "Silence at \(rate) Hz should not decode chars, got: '\(result)'")
        }
    }

    // MARK: - Tone processing at various sample rates

    func testToneProcessingAtVariousSampleRates() {
        let rates: [Float] = [12000, 48000, 44100]
        let toneFreq: Float = 700.0

        for rate in rates {
            let decoder = GGMorseDecoder(sampleRate: rate)
            let numSamples = Int(rate * 0.2) // 200ms of tone
            var tone = [Float](repeating: 0, count: numSamples)
            for i in 0..<numSamples {
                tone[i] = 0.8 * sin(2.0 * .pi * toneFreq * Float(i) / rate)
            }
            _ = decoder.process(samples: tone)
            let silence = [Float](repeating: 0, count: Int(rate * 0.5))
            _ = decoder.process(samples: silence)
            // Verify it doesn't crash at different rates
        }
    }

    // MARK: - Reset preserves functionality

    func testResetPreservesFunctionality() {
        let decoder = GGMorseDecoder(sampleRate: 12000)
        let silence = [Float](repeating: 0, count: 1200)
        _ = decoder.process(samples: silence)
        decoder.reset()
        let result = decoder.process(samples: silence)
        let trimmed = result.trimmingCharacters(in: .whitespaces)
        XCTAssertTrue(trimmed.isEmpty, "Post-reset silence should not produce chars")
    }

    // MARK: - Sample rate update

    func testUpdateSampleRate() {
        let decoder = GGMorseDecoder(sampleRate: 12000)
        XCTAssertEqual(decoder.sampleRate, 12000)
        decoder.updateSampleRate(48000)
        XCTAssertEqual(decoder.sampleRate, 48000)
        // Should still work after rate change
        let silence = [Float](repeating: 0, count: 4800)
        let result = decoder.process(samples: silence)
        let trimmed = result.trimmingCharacters(in: .whitespaces)
        XCTAssertTrue(trimmed.isEmpty)
    }

    func testUpdateSameRateIsNoOp() {
        let decoder = GGMorseDecoder(sampleRate: 12000)
        decoder.updateSampleRate(12000) // should not recreate
        XCTAssertEqual(decoder.sampleRate, 12000)
    }

    func testUpdateInvalidRateIsNoOp() {
        let decoder = GGMorseDecoder(sampleRate: 12000)
        decoder.updateSampleRate(0) // invalid
        XCTAssertEqual(decoder.sampleRate, 12000)
        decoder.updateSampleRate(-1) // invalid
        XCTAssertEqual(decoder.sampleRate, 12000)
    }

    // MARK: - Empty input

    func testEmptyInputReturnsEmpty() {
        let decoder = GGMorseDecoder(sampleRate: 12000)
        let result = decoder.process(samples: [])
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Pitch and WPM properties

    func testInitialPitchAndWpm() {
        let decoder = GGMorseDecoder(sampleRate: 12000)
        // Initial values should be non-negative
        XCTAssertGreaterThanOrEqual(decoder.pitch, 0)
        XCTAssertGreaterThanOrEqual(decoder.wpm, 0)
    }

    // MARK: - AudioEngine effectiveSampleRate

    func testAudioEngineDefaultSampleRate() {
        let engine = AudioEngine()
        XCTAssertEqual(engine.effectiveSampleRate, 12000, "Default sample rate should be 12000")
    }
}
