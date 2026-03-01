import XCTest
@testable import DigiFox

final class WSPRMessagePackTests: XCTestCase {

    // MARK: - WSJT-X Reference: Callsign Encoding

    func testCallsignEncoding_WSJTXReference() {
        // Values verified against WSJT-X wsprd.c character encoding
        // charn: 0-9→0-9, A-Z→10-35, space→36
        XCTAssertEqual(WSPRMessagePack.encodeCallsign("K1JT"), 259055063)
        XCTAssertEqual(WSPRMessagePack.encodeCallsign("DL1ABC"), 96269582)
        XCTAssertEqual(WSPRMessagePack.encodeCallsign("W1AW"), 261410543)
        XCTAssertEqual(WSPRMessagePack.encodeCallsign("VK3XYZ"), 223675369)
    }

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
        let encoded = WSPRMessagePack.encodeCallsign("K1JT")
        let decoded = WSPRMessagePack.decodeCallsign(encoded)
        XCTAssertTrue(decoded.contains("K1JT"), "Should contain K1JT, got '\(decoded)'")
    }

    func testCallsignEncoding_Lowercase() {
        let upper = WSPRMessagePack.encodeCallsign("DL1ABC")
        let lower = WSPRMessagePack.encodeCallsign("dl1abc")
        XCTAssertEqual(upper, lower)
    }

    // MARK: - WSJT-X Reference: Grid Encoding

    func testGridEncoding_WSJTXReference() {
        // WSJT-X formula: (179 - lon) * 180 + lat
        XCTAssertEqual(WSPRMessagePack.encodeGrid("FN20"), 22990)
        XCTAssertEqual(WSPRMessagePack.encodeGrid("JO31"), 15621)
        XCTAssertEqual(WSPRMessagePack.encodeGrid("CM87"), 27307)
        XCTAssertEqual(WSPRMessagePack.encodeGrid("QF22"), 3112)
    }

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
        let result = WSPRMessagePack.encodeGrid("XXXX")
        XCTAssertEqual(result, 32400)
    }

    func testGridEncoding_Range() {
        let grids = ["AA00", "RR99", "JO31"]
        for grid in grids {
            let val = WSPRMessagePack.encodeGrid(grid)
            XCTAssertGreaterThanOrEqual(val, 0, "Grid \(grid) encoded negative")
            XCTAssertLessThan(val, 32400, "Grid \(grid) encoded too large: \(val)")
        }
    }

    // MARK: - Power Encoding

    func testClampPower_ValidLevels() {
        for p in WSPRMessagePack.validPowers {
            XCTAssertEqual(WSPRMessagePack.clampPower(p), p)
        }
    }

    func testClampPower_InvalidLevels() {
        XCTAssertEqual(WSPRMessagePack.clampPower(1), 0)
        XCTAssertEqual(WSPRMessagePack.clampPower(2), 3)
        XCTAssertEqual(WSPRMessagePack.clampPower(5), 3)
        XCTAssertEqual(WSPRMessagePack.clampPower(15), 13)
        XCTAssertEqual(WSPRMessagePack.clampPower(100), 60)
        XCTAssertEqual(WSPRMessagePack.clampPower(-10), 0)
    }

    // MARK: - WSJT-X Reference: Full Message Pack

    func testMessagePack_WSJTXReference() {
        // K1JT FN20 30 — packed bits verified against WSJT-X
        let msg = WSPRMessage(callsign: "K1JT", grid: "FN20", power: 30)
        let bits = WSPRMessagePack.pack(msg)
        let expected: [UInt8] = [
            1,1,1,1,0,1,1,1,0,0,0,0,1,1,0,1,1,1,0,1,1,1,0,1,0,1,1,1,
            1,0,1,1,0,0,1,1,1,0,0,1,1,1,0,1,0,1,1,1,1,0
        ]
        XCTAssertEqual(bits, expected, "Packed bits mismatch for K1JT FN20 30")
    }

    func testMessageRoundTrip() {
        let messages = [
            WSPRMessage(callsign: "DL1ABC", grid: "JO31", power: 30),
            WSPRMessage(callsign: "K1JT", grid: "FN20", power: 37),
            WSPRMessage(callsign: "W1AW", grid: "CM87", power: 10),
        ]
        for msg in messages {
            let bits = WSPRMessagePack.pack(msg)
            XCTAssertEqual(bits.count, 50)
            let recovered = WSPRMessagePack.unpack(bits)
            XCTAssertEqual(recovered.callsign.trimmingCharacters(in: .whitespaces),
                           msg.callsign.trimmingCharacters(in: .whitespaces))
            XCTAssertEqual(recovered.grid, msg.grid)
            XCTAssertEqual(recovered.power, WSPRMessagePack.clampPower(msg.power))
        }
    }

    func testPackBitsAre01Only() {
        let msg = WSPRMessage(callsign: "DL1ABC", grid: "JO31", power: 30)
        let bits = WSPRMessagePack.pack(msg)
        for (i, bit) in bits.enumerated() {
            XCTAssertTrue(bit == 0 || bit == 1, "Bit \(i) is \(bit)")
        }
    }

    func testUnpackShortBits() {
        let short = [UInt8](repeating: 0, count: 10)
        let msg = WSPRMessagePack.unpack(short)
        XCTAssertEqual(msg.callsign, "?????")
    }
}

// MARK: - WSPR Protocol Constants

final class WSPRProtocolTests: XCTestCase {

    func testSyncVectorLength() {
        XCTAssertEqual(WSPRProtocol.syncVector.count, 162)
    }

    func testSyncVectorValues() {
        for val in WSPRProtocol.syncVector {
            XCTAssertTrue(val == 0 || val == 1)
        }
    }

    func testToneSpacing() {
        XCTAssertEqual(WSPRProtocol.toneSpacing, 12000.0 / 8192.0, accuracy: 0.0001)
    }

    func testSymbolDuration() {
        XCTAssertEqual(WSPRProtocol.symbolDuration, 8192.0 / 12000.0, accuracy: 0.0001)
    }

    func testFrameDuration() {
        let expected = 162.0 * 8192.0 / 12000.0
        XCTAssertEqual(WSPRProtocol.frameDuration, expected, accuracy: 0.01)
    }

    func testFrameSamples() {
        XCTAssertEqual(WSPRProtocol.frameSamples, 162 * 8192)
    }

    func testInterleaveIndex_BitReversal() {
        XCTAssertEqual(WSPRProtocol.interleaveIndex(0), 0)
        XCTAssertEqual(WSPRProtocol.interleaveIndex(1), 128)
        XCTAssertEqual(WSPRProtocol.interleaveIndex(128), 1)
        XCTAssertEqual(WSPRProtocol.interleaveIndex(255), 255)
    }

    func testInterleaveIndex_Bijective() {
        var seen = Set<Int>()
        for i in 0..<256 {
            seen.insert(WSPRProtocol.interleaveIndex(i))
        }
        XCTAssertEqual(seen.count, 256)
    }

    func testInterleaveIndex_Involutory() {
        for i in 0..<256 {
            XCTAssertEqual(WSPRProtocol.interleaveIndex(WSPRProtocol.interleaveIndex(i)), i)
        }
    }

    func testConvolutionalPolynomials() {
        XCTAssertEqual(WSPRProtocol.poly1, 0xF2D05351)
        XCTAssertEqual(WSPRProtocol.poly2, 0xE4613C47)
    }
}

// MARK: - WSPR Modulator + WSJT-X Reference Symbols

final class WSPRModulatorTests: XCTestCase {

    func testModulateProducesCorrectSampleCount() {
        let mod = WSPRModulator()
        let msg = WSPRMessage(callsign: "DL1ABC", grid: "JO31", power: 30)
        let samples = mod.modulate(msg)
        XCTAssertEqual(samples.count, WSPRProtocol.frameSamples)
    }

    func testModulateAmplitudeRange() {
        let mod = WSPRModulator()
        mod.amplitude = 0.5
        let msg = WSPRMessage(callsign: "K1JT", grid: "FN20", power: 37)
        let samples = mod.modulate(msg)
        let maxAbs = samples.map { abs($0) }.max() ?? 0
        XCTAssertLessThanOrEqual(maxAbs, 0.55)
        XCTAssertGreaterThan(maxAbs, 0.3)
    }

    func testModulateStartsAndEndsQuietly() {
        let mod = WSPRModulator()
        mod.rampDuration = 0.005
        let msg = WSPRMessage(callsign: "W1AW", grid: "CM87", power: 10)
        let samples = mod.modulate(msg)
        XCTAssertEqual(abs(samples[0]), 0.0, accuracy: 0.01)
        XCTAssertEqual(abs(samples.last!), 0.0, accuracy: 0.01)
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

    /// Verify channel symbols match WSJT-X reference for K1JT FN20 30.
    /// This is the definitive interop test: if symbols match, signals are decodable by WSJT-X.
    func testChannelSymbols_WSJTXReference() {
        let mod = WSPRModulator()
        let msg = WSPRMessage(callsign: "K1JT", grid: "FN20", power: 30)
        let samples = mod.modulate(msg)

        // Extract symbols from generated audio by detecting dominant tone per symbol period
        let symbolSamples = WSPRProtocol.symbolSamples  // 8192
        let baseFreq = mod.baseFrequency
        let toneSpacing = WSPRProtocol.toneSpacing
        let sampleRate = WSPRProtocol.sampleRate

        var detectedSymbols = [Int]()
        for symIdx in 0..<WSPRProtocol.symbolCount {
            let start = symIdx * symbolSamples
            let end = min(start + symbolSamples, samples.count)
            guard end > start else { break }

            // Measure power at each of the 4 tone frequencies
            var bestTone = 0
            var bestPower: Double = -1
            for tone in 0..<4 {
                let freq = baseFreq + Double(tone) * toneSpacing
                var sumCos: Double = 0
                var sumSin: Double = 0
                // Use central portion to avoid ramp
                let midStart = start + symbolSamples / 8
                let midEnd = end - symbolSamples / 8
                for j in midStart..<midEnd {
                    let t = Double(j) / sampleRate
                    sumCos += Double(samples[j]) * cos(2.0 * .pi * freq * t)
                    sumSin += Double(samples[j]) * sin(2.0 * .pi * freq * t)
                }
                let power = sumCos * sumCos + sumSin * sumSin
                if power > bestPower {
                    bestPower = power
                    bestTone = tone
                }
            }
            detectedSymbols.append(bestTone)
        }

        // WSJT-X reference symbols for "K1JT FN20 30"
        let expected = [
            3,3,2,0,0,0,0,0,1,2,0,0,1,1,3,0,2,0,3,0,
            2,1,0,1,1,1,3,0,0,0,0,0,2,2,1,0,0,1,0,1,
            2,2,2,0,2,0,1,0,3,1,2,0,1,1,2,1,0,0,2,1,
            3,0,3,0,2,0,0,1,1,0,1,0,1,2,1,0,1,0,0,1,
            0,2,3,0,3,1,2,0,0,3,3,0,1,0,1,0,2,0,1,0,
            2,0,0,0,1,2,2,1,2,0,1,1,3,2,3,1,2,0,3,1,
            2,3,0,0,2,1,3,1,2,0,2,0,0,1,2,1,2,2,3,1,
            2,0,0,0,0,2,0,1,3,0,1,0,3,3,2,0,0,1,1,0,
            2,0
        ]

        XCTAssertEqual(detectedSymbols.count, expected.count,
                       "Symbol count mismatch: got \(detectedSymbols.count), expected \(expected.count)")

        var mismatches = 0
        for i in 0..<min(detectedSymbols.count, expected.count) {
            if detectedSymbols[i] != expected[i] {
                mismatches += 1
            }
        }
        XCTAssertEqual(mismatches, 0,
                       "Symbol mismatches: \(mismatches)/\(expected.count) — signals incompatible with WSJT-X")
    }

    func testFrameDurationProperty() {
        let mod = WSPRModulator()
        XCTAssertEqual(mod.frameDuration, WSPRProtocol.frameDuration, accuracy: 0.001)
    }
}
