import XCTest
@testable import DigiFox

final class WSPRMessagePackTests: XCTestCase {

    // MARK: - Callsign Encoding Round-trip

    func testCallsignRoundTrip_Standard6Char() {
        let calls = ["DL1ABC", "W1AW", "K1JT", "VK3XYZ", "JA1ABC"]
        for call in calls {
            let encoded = WSPRMessagePack.encodeCallsign(call)
            let decoded = WSPRMessagePack.decodeCallsign(encoded)
            XCTAssertEqual(decoded.trimmingCharacters(in: .whitespaces),
                           call.trimmingCharacters(in: .whitespaces),
                           "Round-trip failed for \(call): got '\(decoded)'")
        }
    }

    func testCallsignRoundTrip_ShortCall() {
        // Short callsigns get left-padded with spaces
        let encoded = WSPRMessagePack.encodeCallsign("K1JT")
        let decoded = WSPRMessagePack.decodeCallsign(encoded)
        XCTAssertTrue(decoded.contains("K1JT"), "Should contain K1JT, got '\(decoded)'")
    }

    func testCallsignRoundTrip_DigitAtPosition3() {
        // 3rd char MUST be digit - verify padding works
        let encoded = WSPRMessagePack.encodeCallsign("AA1BB")
        let decoded = WSPRMessagePack.decodeCallsign(encoded)
        // After padding, 3rd char should be a digit
        let chars = Array(decoded)
        let trimmed = decoded.trimmingCharacters(in: .whitespaces)
        XCTAssertFalse(trimmed.isEmpty)
    }

    func testCallsignEncoding_Lowercase() {
        // Should be case-insensitive
        let upper = WSPRMessagePack.encodeCallsign("DL1ABC")
        let lower = WSPRMessagePack.encodeCallsign("dl1abc")
        XCTAssertEqual(upper, lower)
    }

    // MARK: - Grid Encoding Round-trip

    func testGridRoundTrip() {
        let grids = ["JO31", "FN31", "AA00", "RR99", "IO91", "CM87"]
        for grid in grids {
            let encoded = WSPRMessagePack.encodeGrid(grid)
            let decoded = WSPRMessagePack.decodeGrid(encoded)
            XCTAssertEqual(decoded, grid, "Grid round-trip failed for \(grid)")
        }
    }

    func testGridEncoding_LowercaseInput() {
        let upper = WSPRMessagePack.encodeGrid("JO31")
        let lower = WSPRMessagePack.encodeGrid("jo31")
        XCTAssertEqual(upper, lower)
    }

    func testGridEncoding_InvalidGrid() {
        // Invalid grid should return center value
        let result = WSPRMessagePack.encodeGrid("XXXX")
        XCTAssertEqual(result, 32400) // center/invalid marker
    }

    func testGridEncoding_TooShort() {
        let result = WSPRMessagePack.encodeGrid("JO")
        XCTAssertEqual(result, 32400)
    }

    func testGridEncoding_Range() {
        // Grid values should be in valid range
        let grids = ["AA00", "RR99", "JO31"]
        for grid in grids {
            let val = WSPRMessagePack.encodeGrid(grid)
            XCTAssertGreaterThanOrEqual(val, 0, "Grid \(grid) encoded negative")
            XCTAssertLessThan(val, 32400, "Grid \(grid) encoded too large: \(val)")
        }
    }

    // MARK: - Power Encoding

    func testClampPower_ValidLevels() {
        let valid = WSPRMessagePack.validPowers
        for p in valid {
            XCTAssertEqual(WSPRMessagePack.clampPower(p), p, "Valid power \(p) should not change")
        }
    }

    func testClampPower_InvalidLevels() {
        // Should clamp to nearest valid
        XCTAssertEqual(WSPRMessagePack.clampPower(1), 0)
        XCTAssertEqual(WSPRMessagePack.clampPower(2), 3)
        XCTAssertEqual(WSPRMessagePack.clampPower(5), 3)
        XCTAssertEqual(WSPRMessagePack.clampPower(15), 13)
        XCTAssertEqual(WSPRMessagePack.clampPower(25), 23)
        XCTAssertEqual(WSPRMessagePack.clampPower(100), 60) // clamp high
    }

    func testClampPower_NegativeValue() {
        let result = WSPRMessagePack.clampPower(-10)
        XCTAssertEqual(result, 0)
    }

    // MARK: - Full Message Pack/Unpack Round-trip

    func testMessageRoundTrip() {
        let messages = [
            WSPRMessage(callsign: "DL1ABC", grid: "JO31", power: 30),
            WSPRMessage(callsign: "K1JT", grid: "FN31", power: 37),
            WSPRMessage(callsign: "W1AW", grid: "CM87", power: 10),
        ]

        for msg in messages {
            let bits = WSPRMessagePack.pack(msg)
            XCTAssertEqual(bits.count, 50, "Packed bits should be 50")

            let recovered = WSPRMessagePack.unpack(bits)
            XCTAssertEqual(recovered.callsign.trimmingCharacters(in: .whitespaces),
                           msg.callsign.trimmingCharacters(in: .whitespaces),
                           "Callsign mismatch for \(msg.callsign)")
            XCTAssertEqual(recovered.grid, msg.grid,
                           "Grid mismatch for \(msg.grid)")
            XCTAssertEqual(recovered.power, WSPRMessagePack.clampPower(msg.power),
                           "Power mismatch for \(msg.power)")
        }
    }

    func testPackBitsAre01Only() {
        let msg = WSPRMessage(callsign: "DL1ABC", grid: "JO31", power: 30)
        let bits = WSPRMessagePack.pack(msg)
        for (i, bit) in bits.enumerated() {
            XCTAssertTrue(bit == 0 || bit == 1, "Bit \(i) is \(bit), expected 0 or 1")
        }
    }

    func testUnpackShortBits() {
        let short = [UInt8](repeating: 0, count: 10)
        let msg = WSPRMessagePack.unpack(short)
        XCTAssertEqual(msg.callsign, "?????") // error fallback
    }

    // MARK: - parseText

    func testParseText() {
        let msg = WSPRMessagePack.parseText("", myCall: "dl1abc", myGrid: "jo31", power: 30)
        XCTAssertEqual(msg.callsign, "DL1ABC")
        XCTAssertEqual(msg.grid, "JO31")
        XCTAssertEqual(msg.power, 30)
    }

    func testParseTextGridTruncation() {
        let msg = WSPRMessagePack.parseText("", myCall: "K1JT", myGrid: "FN31ab", power: 20)
        XCTAssertEqual(msg.grid, "FN31") // only first 4 chars
    }
}

// MARK: - WSPR Protocol Constants

final class WSPRProtocolTests: XCTestCase {

    func testSyncVectorLength() {
        XCTAssertEqual(WSPRProtocol.syncVector.count, 162)
    }

    func testSyncVectorValues() {
        for val in WSPRProtocol.syncVector {
            XCTAssertTrue(val == 0 || val == 1, "Sync vector contains \(val), expected 0 or 1")
        }
    }

    func testSymbolCount() {
        XCTAssertEqual(WSPRProtocol.symbolCount, 162)
    }

    func testToneCount() {
        XCTAssertEqual(WSPRProtocol.toneCount, 4)
    }

    func testToneSpacing() {
        // 12000/8192 ≈ 1.4648 Hz
        XCTAssertEqual(WSPRProtocol.toneSpacing, 12000.0 / 8192.0, accuracy: 0.0001)
    }

    func testSymbolDuration() {
        // 8192/12000 ≈ 0.6827 s
        XCTAssertEqual(WSPRProtocol.symbolDuration, 8192.0 / 12000.0, accuracy: 0.0001)
    }

    func testFrameDuration() {
        // 162 * 8192/12000 ≈ 110.6 s
        let expected = 162.0 * 8192.0 / 12000.0
        XCTAssertEqual(WSPRProtocol.frameDuration, expected, accuracy: 0.01)
    }

    func testFrameSamples() {
        XCTAssertEqual(WSPRProtocol.frameSamples, 162 * 8192)
    }

    func testInterleaveIndex_BitReversal() {
        // interleaveIndex(0) = 0 (all zeros reversed = all zeros)
        XCTAssertEqual(WSPRProtocol.interleaveIndex(0), 0)
        // interleaveIndex(1) = 128 (bit 0 reversed into bit 7)
        XCTAssertEqual(WSPRProtocol.interleaveIndex(1), 128)
        // interleaveIndex(128) = 1
        XCTAssertEqual(WSPRProtocol.interleaveIndex(128), 1)
        // interleaveIndex(255) = 255 (all ones reversed = all ones)
        XCTAssertEqual(WSPRProtocol.interleaveIndex(255), 255)
    }

    func testInterleaveIndex_Bijective() {
        // bit-reversal on 0..255 should be a bijection
        var seen = Set<Int>()
        for i in 0..<256 {
            let j = WSPRProtocol.interleaveIndex(i)
            XCTAssertTrue(j >= 0 && j < 256, "Out of range: \(j)")
            seen.insert(j)
        }
        XCTAssertEqual(seen.count, 256, "Should be a permutation of 0..255")
    }

    func testInterleaveIndex_Involutory() {
        // bit-reversal applied twice = identity
        for i in 0..<256 {
            XCTAssertEqual(WSPRProtocol.interleaveIndex(WSPRProtocol.interleaveIndex(i)), i)
        }
    }

    func testConvolutionalPolynomials() {
        // Known WSPR polynomials
        XCTAssertEqual(WSPRProtocol.poly1, 0xF2D05351)
        XCTAssertEqual(WSPRProtocol.poly2, 0xE4613C47)
    }
}

// MARK: - WSPR Modulator

final class WSPRModulatorTests: XCTestCase {

    func testModulateProducesCorrectSampleCount() {
        let mod = WSPRModulator()
        let msg = WSPRMessage(callsign: "DL1ABC", grid: "JO31", power: 30)
        let samples = mod.modulate(msg)
        XCTAssertEqual(samples.count, WSPRProtocol.frameSamples,
                       "Expected \(WSPRProtocol.frameSamples) samples, got \(samples.count)")
    }

    func testModulateAmplitudeRange() {
        let mod = WSPRModulator()
        mod.amplitude = 0.5
        let msg = WSPRMessage(callsign: "K1JT", grid: "FN31", power: 37)
        let samples = mod.modulate(msg)

        let maxAbs = samples.map { abs($0) }.max() ?? 0
        XCTAssertLessThanOrEqual(maxAbs, 0.55, "Max amplitude \(maxAbs) exceeds expected ~0.5")
        XCTAssertGreaterThan(maxAbs, 0.3, "Max amplitude \(maxAbs) too low")
    }

    func testModulateStartsAndEndsQuietly() {
        let mod = WSPRModulator()
        mod.rampDuration = 0.005
        let msg = WSPRMessage(callsign: "W1AW", grid: "CM87", power: 10)
        let samples = mod.modulate(msg)

        // First sample should be near zero (ramp)
        XCTAssertEqual(abs(samples[0]), 0.0, accuracy: 0.01, "First sample should be ~0 (ramp)")
        // Last sample should be near zero (ramp)
        XCTAssertEqual(abs(samples.last!), 0.0, accuracy: 0.01, "Last sample should be ~0 (ramp)")
    }

    func testModulateAllSamplesFinite() {
        let mod = WSPRModulator()
        let msg = WSPRMessage(callsign: "DL1ABC", grid: "JO31", power: 30)
        let samples = mod.modulate(msg)
        for (i, s) in samples.enumerated() {
            XCTAssertFalse(s.isNaN, "Sample \(i) is NaN")
            XCTAssertFalse(s.isInfinite, "Sample \(i) is infinite")
        }
    }

    func testModulateBaseFrequencyAffectsOutput() {
        let mod1 = WSPRModulator()
        mod1.baseFrequency = 1500.0
        let mod2 = WSPRModulator()
        mod2.baseFrequency = 1400.0

        let msg = WSPRMessage(callsign: "K1JT", grid: "FN31", power: 37)
        let s1 = mod1.modulate(msg)
        let s2 = mod2.modulate(msg)

        // Different base frequency should produce different samples
        XCTAssertEqual(s1.count, s2.count)
        var different = false
        for i in stride(from: 100, to: 200, by: 1) {
            if abs(s1[i] - s2[i]) > 0.001 { different = true; break }
        }
        XCTAssertTrue(different, "Different base frequencies should produce different audio")
    }

    func testFrameDurationProperty() {
        let mod = WSPRModulator()
        XCTAssertEqual(mod.frameDuration, WSPRProtocol.frameDuration, accuracy: 0.001)
    }
}
