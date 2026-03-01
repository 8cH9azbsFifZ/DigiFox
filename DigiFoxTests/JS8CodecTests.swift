import XCTest
@testable import DigiFox

/// Verify the JS8 codec against known reference values and roundtrip tests.
final class JS8CodecTests: XCTestCase {

    // MARK: - Gray Code Tables

    func testGrayCodeTables() {
        // Reference Gray code mapping from WSJT-X kFT8_Gray_map
        let expectedEncode = [0, 1, 3, 2, 5, 6, 4, 7]
        XCTAssertEqual(JS8Protocol.grayEncode, expectedEncode)

        // Verify decode is the inverse of encode
        for i in 0..<8 {
            let gray = JS8Protocol.grayEncode[i]
            XCTAssertEqual(JS8Protocol.grayDecode[gray], i,
                           "grayDecode[\(gray)] should be \(i)")
        }
    }

    func testGrayCodeMatchesFT8() {
        // JS8 and FT8 must use identical Gray code tables
        XCTAssertEqual(JS8Protocol.grayEncode, FT8Protocol.grayEncode)
        XCTAssertEqual(JS8Protocol.grayDecode, FT8Protocol.grayDecode)
    }

    // MARK: - Protocol Constants

    func testProtocolConstants() {
        // Costas array from WSJT-X
        XCTAssertEqual(JS8Protocol.costas, [3, 1, 4, 0, 6, 5, 2])
        XCTAssertEqual(JS8Protocol.symbolCount, 79)
        XCTAssertEqual(JS8Protocol.dataSymbolCount, 58)
        XCTAssertEqual(JS8Protocol.costasLength, 7)
        XCTAssertEqual(JS8Protocol.codewordBits, 174)
        XCTAssertEqual(JS8Protocol.messageBits, 91)
        XCTAssertEqual(JS8Protocol.payloadBits, 77)
        XCTAssertEqual(JS8Protocol.crcBits, 14)
        XCTAssertEqual(JS8Protocol.toneCount, 8)
        XCTAssertEqual(JS8Protocol.bitsPerSymbol, 3)
    }

    func testSyncPositions() {
        // Costas at positions 0-6, 36-42, 72-78
        let expected = Set((0...6) + (36...42) + (72...78))
        XCTAssertEqual(JS8Protocol.syncPositions, expected)
        XCTAssertEqual(JS8Protocol.syncPositions.count, 21)
    }

    func testDataPositions() {
        XCTAssertEqual(JS8Protocol.dataPositions.count, 58)
        // Data positions must not overlap with sync positions
        for pos in JS8Protocol.dataPositions {
            XCTAssertFalse(JS8Protocol.syncPositions.contains(pos),
                           "Data position \(pos) overlaps with sync")
        }
        // Together they should cover all 79 positions
        let all = Set(JS8Protocol.dataPositions).union(JS8Protocol.syncPositions)
        XCTAssertEqual(all, Set(0..<79))
    }

    func testSpeedModeParameters() {
        // Verify tone spacing = sampleRate / symbolSamples
        for speed in JS8Speed.allCases {
            let expected = JS8Protocol.sampleRate / Double(speed.symbolSamples)
            XCTAssertEqual(JS8Protocol.toneSpacing(for: speed), expected, accuracy: 1e-10)
        }
        // Known values
        XCTAssertEqual(JS8Speed.normal.symbolSamples, 1920)
        XCTAssertEqual(JS8Speed.fast.symbolSamples, 1280)
        XCTAssertEqual(JS8Speed.turbo.symbolSamples, 640)
        XCTAssertEqual(JS8Speed.slow.symbolSamples, 3840)
        XCTAssertEqual(JS8Speed.ultra.symbolSamples, 7680)
    }

    // MARK: - CRC-14

    func testCRCRoundTrip() {
        let payload: [UInt8] = [1, 0, 1, 1, 0, 0, 1, 0, 1, 0,
                                0, 1, 1, 0, 1, 0, 1, 1, 0, 0,
                                1, 0, 0, 1, 0, 1, 1, 0, 0, 1,
                                0, 1, 0, 0, 1, 1, 0, 1, 0, 1,
                                1, 0, 0, 1, 0, 1, 0, 1, 1, 0,
                                0, 1, 0, 1, 1, 0, 0, 1, 0, 1,
                                0, 1, 1, 0, 0, 1, 0, 1, 0, 0,
                                1, 1, 0, 1, 0, 1, 1]
        let withCRC = JS8CRC.append(to: payload)
        XCTAssertEqual(withCRC.count, 91, "77 payload + 14 CRC = 91 bits")
        XCTAssertTrue(JS8CRC.validate(withCRC))

        // Flip a bit → CRC must fail
        var corrupted = withCRC
        corrupted[10] ^= 1
        XCTAssertFalse(JS8CRC.validate(corrupted))
    }

    func testCRCPolynomial() {
        XCTAssertEqual(JS8CRC.polynomial, 0x2757)
    }

    // MARK: - PackMessage

    func testPackUnpackRoundTrip() {
        let messages = ["CQ DL1ABC", "HELLO WORLD", "TEST 123", "CQ CQ CQ",
                        "73 DE DL1ABC", "QSL TNX", "+-./?@"]
        for msg in messages {
            let packed = PackMessage.pack(msg)
            XCTAssertEqual(packed.count, 77, "Packed message must be 77 bits")
            let unpacked = PackMessage.unpack(packed)
            let expected = String((msg.uppercased() + String(repeating: " ", count: 13)).prefix(13))
                .trimmingCharacters(in: .whitespaces)
            XCTAssertEqual(unpacked, expected,
                           "Roundtrip failed for '\(msg)': got '\(unpacked)'")
        }
    }

    func testPackMessageCharset() {
        // Charset must be exactly 43 characters
        XCTAssertEqual(JS8Protocol.charset.count, 43)
        XCTAssertEqual(JS8Protocol.charsetSize, 43)
        // First char is space
        XCTAssertEqual(JS8Protocol.charset[0], Character(" "))
        // Last char is @
        XCTAssertEqual(JS8Protocol.charset[42], Character("@"))
    }

    // MARK: - LDPC Encode/Decode Roundtrip

    func testLDPCRoundTrip() {
        // Create a 91-bit message (77 payload + 14 CRC)
        let payload = PackMessage.pack("CQ DL1ABC")
        let message = JS8CRC.append(to: payload)
        XCTAssertEqual(message.count, 91)

        let codeword = LDPC.encode(message)
        XCTAssertEqual(codeword.count, 174)

        // First 91 bits should be the message (systematic code)
        XCTAssertEqual(Array(codeword.prefix(91)), message)

        // Decode with perfect LLRs (no noise)
        let llr: [Float] = codeword.map { $0 == 0 ? 1.0 : -1.0 }
        let decoded = LDPC.decode(llr)
        XCTAssertNotNil(decoded, "LDPC decode should succeed with perfect input")
        XCTAssertEqual(decoded!, message, "Decoded message must match original")
    }

    func testLDPCWithNoise() {
        // LDPC should correct a few bit errors
        let payload = PackMessage.pack("HELLO")
        let message = JS8CRC.append(to: payload)
        let codeword = LDPC.encode(message)

        // Add soft noise — flip signs of a few bits
        var llr: [Float] = codeword.map { $0 == 0 ? 2.0 : -2.0 }
        // Corrupt 5 bits (LDPC should handle this)
        for i in [10, 30, 50, 100, 150] {
            llr[i] = -llr[i] * 0.3  // weak flip
        }

        let decoded = LDPC.decode(llr)
        XCTAssertNotNil(decoded, "LDPC should correct a few errors")
        if let decoded = decoded {
            XCTAssertTrue(JS8CRC.validate(decoded))
            let text = PackMessage.unpack(Array(decoded.prefix(77)))
            XCTAssertEqual(text, "HELLO")
        }
    }

    // MARK: - Full Modulator Roundtrip

    func testModulatorProducesCorrectFrameLength() {
        let mod = JS8Modulator()
        for speed in JS8Speed.allCases {
            let audio = mod.modulate(message: "TEST", frequency: 1000, speed: speed)
            let expectedSamples = JS8Protocol.symbolCount * speed.symbolSamples
            XCTAssertEqual(audio.count, expectedSamples,
                           "Frame length wrong for \(speed.name)")
        }
    }

    func testModulatorAudioNotSilent() {
        let mod = JS8Modulator()
        let audio = mod.modulate(message: "CQ DL1ABC", frequency: 1000, speed: .normal)
        let peak = audio.map { abs($0) }.max() ?? 0
        XCTAssertGreaterThan(peak, 0.5, "Audio should not be silent")
    }

    // MARK: - Modulator → Demodulator Roundtrip

    func testFullRoundTrip() {
        let mod = JS8Modulator()
        let demod = JS8Demodulator()
        let message = "CQ DL1ABC"
        let freq = 1500.0

        // Encode
        let audio = mod.modulate(message: message, frequency: freq, speed: .normal)

        // Add silence padding (demodulator needs a full buffer)
        let paddedAudio = [Float](repeating: 0, count: 1920) + audio + [Float](repeating: 0, count: 1920)

        // Decode
        let results = demod.demodulate(samples: paddedAudio, speed: .normal,
                                        freqRange: (freq - 100)...(freq + 100))

        XCTAssertFalse(results.isEmpty, "Should decode at least one message")
        if let first = results.first {
            XCTAssertEqual(first.message, "CQ DL1ABC",
                           "Decoded message should match: got '\(first.message)'")
        }
    }
}
