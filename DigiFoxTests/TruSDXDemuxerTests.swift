import XCTest
@testable import DigiFox

final class TruSDXDemuxerTests: XCTestCase {

    var demuxer: TruSDXDemuxer!

    override func setUp() {
        super.setUp()
        demuxer = TruSDXDemuxer()
    }

    // MARK: - Basic Audio Streaming

    /// Audio block: ;US<samples>;
    func testBasicAudioBlock() {
        // ;US followed by 3 audio bytes, then ;
        let data = Data([
            0x3B,                   // ;
            UInt8(ascii: "U"),      // U
            UInt8(ascii: "S"),      // S
            0x80, 0xA0, 0x60,      // 3 audio samples (128=0.0, 160=+0.25, 96=-0.25)
            0x3B                    // ; (end of audio block)
        ])

        let result = demuxer.process(data)

        XCTAssertEqual(result.audioSamples.count, 3)
        XCTAssertEqual(result.audioSamples[0], 0.0, accuracy: 0.01)        // 128 → 0.0
        XCTAssertEqual(result.audioSamples[1], 0.25, accuracy: 0.01)       // 160 → +0.25
        XCTAssertEqual(result.audioSamples[2], -0.25, accuracy: 0.01)      // 96 → -0.25
        XCTAssertTrue(result.catResponses.isEmpty)
    }

    /// Silence (byte 0x80 = 128) should decode to 0.0
    func testSilence() {
        let data = Data([0x3B, UInt8(ascii: "U"), UInt8(ascii: "S")]
            + [UInt8](repeating: 0x80, count: 100)
            + [0x3B])

        let result = demuxer.process(data)

        XCTAssertEqual(result.audioSamples.count, 100)
        for sample in result.audioSamples {
            XCTAssertEqual(sample, 0.0, accuracy: 0.001)
        }
    }

    /// Maximum positive sample (0xFF = 255) → ~+0.992
    func testMaxPositiveSample() {
        let data = Data([0x3B, UInt8(ascii: "U"), UInt8(ascii: "S"), 0xFF, 0x3B])
        let result = demuxer.process(data)

        XCTAssertEqual(result.audioSamples.count, 1)
        XCTAssertEqual(result.audioSamples[0], (255.0 - 128.0) / 128.0, accuracy: 0.001)
    }

    /// Minimum sample (0x00 = 0) → -1.0
    func testMinSample() {
        let data = Data([0x3B, UInt8(ascii: "U"), UInt8(ascii: "S"), 0x00, 0x3B])
        let result = demuxer.process(data)

        XCTAssertEqual(result.audioSamples.count, 1)
        XCTAssertEqual(result.audioSamples[0], -1.0, accuracy: 0.001)
    }

    /// The firmware never sends 0x3B as audio (increments to 0x3C).
    /// Verify 0x3C is treated as audio, not as a delimiter.
    func testSemicolonAvoidance() {
        // Byte 0x3C (60) should be decoded as audio, not treated as ';'
        let data = Data([0x3B, UInt8(ascii: "U"), UInt8(ascii: "S"), 0x3C, 0x80, 0x3B])
        let result = demuxer.process(data)

        XCTAssertEqual(result.audioSamples.count, 2)
        XCTAssertEqual(result.audioSamples[0], (60.0 - 128.0) / 128.0, accuracy: 0.001) // 0x3C
        XCTAssertEqual(result.audioSamples[1], 0.0, accuracy: 0.001)                     // 0x80
    }

    // MARK: - Basic CAT Responses

    /// Simple CAT response: FA00007074000;
    func testCATResponse() {
        let cmd = "FA00007074000;"
        let data = Data(cmd.utf8)
        let result = demuxer.process(data)

        XCTAssertTrue(result.audioSamples.isEmpty)
        XCTAssertEqual(result.catResponses.count, 1)
        XCTAssertEqual(result.catResponses[0], "FA00007074000;")
    }

    /// Multiple CAT responses in sequence
    func testMultipleCATResponses() {
        let data = Data("FA00007074000;MD2;".utf8)
        let result = demuxer.process(data)

        XCTAssertEqual(result.catResponses.count, 2)
        XCTAssertEqual(result.catResponses[0], "FA00007074000;")
        XCTAssertEqual(result.catResponses[1], "MD2;")
    }

    /// UA1; confirmation response
    func testUA1Confirmation() {
        let data = Data("UA1;".utf8)
        let result = demuxer.process(data)

        XCTAssertEqual(result.catResponses.count, 1)
        XCTAssertEqual(result.catResponses[0], "UA1;")
    }

    // MARK: - Interleaved Audio and CAT

    /// Firmware pattern: ;US[audio];[CAT response];US[audio];
    func testInterleavedAudioAndCAT() {
        // ;US<audio>; FA00007074000; US<audio>;
        var data = Data()
        // First audio block
        data.append(contentsOf: [0x3B, UInt8(ascii: "U"), UInt8(ascii: "S")])
        data.append(contentsOf: [0x80, 0x80, 0x80]) // 3 silence samples
        // CAT response interrupts
        data.append(contentsOf: [0x3B]) // end audio / start potential CAT
        data.append(contentsOf: Data("FA00007074000;".utf8))
        // Audio resumes
        data.append(contentsOf: [UInt8(ascii: "U"), UInt8(ascii: "S")])
        data.append(contentsOf: [0xA0, 0xA0]) // 2 audio samples
        data.append(contentsOf: [0x3B]) // end audio

        let result = demuxer.process(data)

        XCTAssertEqual(result.audioSamples.count, 5) // 3 + 2
        XCTAssertEqual(result.catResponses.count, 1)
        XCTAssertEqual(result.catResponses[0], "FA00007074000;")
    }

    /// Multiple CAT responses between audio blocks
    func testMultipleCATBetweenAudio() {
        var data = Data()
        // Audio block
        data.append(contentsOf: [0x3B, UInt8(ascii: "U"), UInt8(ascii: "S")])
        data.append(contentsOf: [0x80, 0x80])
        // Two CAT responses
        data.append(contentsOf: Data(";FA00007074000;MD2;".utf8))
        // Audio resumes
        data.append(contentsOf: [UInt8(ascii: "U"), UInt8(ascii: "S")])
        data.append(contentsOf: [0xC0])
        data.append(contentsOf: [0x3B])

        let result = demuxer.process(data)

        XCTAssertEqual(result.audioSamples.count, 3) // 2 + 1
        XCTAssertEqual(result.catResponses.count, 2)
        XCTAssertEqual(result.catResponses[0], "FA00007074000;")
        XCTAssertEqual(result.catResponses[1], "MD2;")
    }

    // MARK: - State Machine Edge Cases

    /// Data arriving in small chunks (byte by byte) should work correctly
    func testByteByByteProcessing() {
        // Send ;US<0x80><0xA0>; byte by byte
        let bytes: [UInt8] = [0x3B, UInt8(ascii: "U"), UInt8(ascii: "S"), 0x80, 0xA0, 0x3B]

        var totalAudio = [Float]()
        var totalCAT = [String]()

        for byte in bytes {
            let result = demuxer.process(Data([byte]))
            totalAudio.append(contentsOf: result.audioSamples)
            totalCAT.append(contentsOf: result.catResponses)
        }

        XCTAssertEqual(totalAudio.count, 2)
        XCTAssertEqual(totalAudio[0], 0.0, accuracy: 0.01)    // 0x80
        XCTAssertEqual(totalAudio[1], 0.25, accuracy: 0.01)   // 0xA0
    }

    /// ";U" followed by non-"S" should NOT be treated as audio prefix
    func testFalseUSPrefix() {
        // ;UD is a display command, not audio
        let data = Data(";UD0116chars here ;".utf8)
        let result = demuxer.process(data)

        // "UD0116chars here ;" should be a CAT response (the U was part of UD, not US)
        XCTAssertTrue(result.audioSamples.isEmpty)
        // After ;, U is consumed, then D → catBuffer gets "UD", continues until next ;
        XCTAssertEqual(result.catResponses.count, 1)
        XCTAssertTrue(result.catResponses[0].hasPrefix("UD"))
    }

    /// ";U" at end of chunk, "S" at start of next chunk
    func testSplitUSAcrossChunks() {
        let chunk1 = Data([0x3B, UInt8(ascii: "U")])
        let chunk2 = Data([UInt8(ascii: "S"), 0x80, 0x80, 0x3B])

        let r1 = demuxer.process(chunk1)
        let r2 = demuxer.process(chunk2)

        XCTAssertTrue(r1.audioSamples.isEmpty)
        XCTAssertEqual(r2.audioSamples.count, 2) // audio properly decoded
    }

    /// ";" at end of chunk, "US" at start of next
    func testSplitSemicolonAcrossChunks() {
        let chunk1 = Data([0x3B])
        let chunk2 = Data([UInt8(ascii: "U"), UInt8(ascii: "S"), 0xC0, 0x3B])

        let r1 = demuxer.process(chunk1)
        let r2 = demuxer.process(chunk2)

        XCTAssertTrue(r1.audioSamples.isEmpty)
        XCTAssertEqual(r2.audioSamples.count, 1)
        XCTAssertEqual(r2.audioSamples[0], (192.0 - 128.0) / 128.0, accuracy: 0.001)
    }

    /// Empty data should return empty results
    func testEmptyData() {
        let result = demuxer.process(Data())
        XCTAssertTrue(result.audioSamples.isEmpty)
        XCTAssertTrue(result.catResponses.isEmpty)
    }

    /// Reset clears state
    func testReset() {
        // Start receiving a CAT command
        _ = demuxer.process(Data("FA0000".utf8))
        demuxer.reset()

        // Now process a complete command - should not contain leftover
        let result = demuxer.process(Data("MD2;".utf8))
        XCTAssertEqual(result.catResponses.count, 1)
        XCTAssertEqual(result.catResponses[0], "MD2;")
    }

    /// Long continuous audio stream
    func testLongAudioStream() {
        var data = Data([0x3B, UInt8(ascii: "U"), UInt8(ascii: "S")])
        // 1000 audio samples (all non-0x3B values)
        for i in 0..<1000 {
            var byte = UInt8(i % 256)
            if byte == 0x3B { byte = 0x3C } // avoid semicolon
            data.append(byte)
        }
        data.append(0x3B) // end

        let result = demuxer.process(data)

        XCTAssertEqual(result.audioSamples.count, 1000)
        XCTAssertTrue(result.catResponses.isEmpty)
    }

    /// Consecutive audio blocks without CAT in between
    func testConsecutiveAudioBlocks() {
        var data = Data()
        // Block 1
        data.append(contentsOf: [0x3B, UInt8(ascii: "U"), UInt8(ascii: "S"), 0x80, 0x80, 0x80])
        // Block 2 (immediately after ';')
        data.append(contentsOf: [0x3B, UInt8(ascii: "U"), UInt8(ascii: "S"), 0xA0, 0xA0])
        data.append(0x3B)

        let result = demuxer.process(data)

        XCTAssertEqual(result.audioSamples.count, 5) // 3 + 2
        XCTAssertTrue(result.catResponses.isEmpty)
    }

    // MARK: - Byte ↔ Sample Conversion

    func testByteToSample() {
        XCTAssertEqual(TruSDXDemuxer.byteToSample(128), 0.0, accuracy: 0.001)
        XCTAssertEqual(TruSDXDemuxer.byteToSample(0), -1.0, accuracy: 0.001)
        XCTAssertEqual(TruSDXDemuxer.byteToSample(255), 127.0 / 128.0, accuracy: 0.001)
        XCTAssertEqual(TruSDXDemuxer.byteToSample(64), -0.5, accuracy: 0.001)
        XCTAssertEqual(TruSDXDemuxer.byteToSample(192), 0.5, accuracy: 0.001)
    }

    func testSampleToByte() {
        XCTAssertEqual(TruSDXDemuxer.sampleToByte(0.0), 128)
        XCTAssertEqual(TruSDXDemuxer.sampleToByte(-1.0), 1)   // -1.0 * 127 + 128 = 1
        XCTAssertEqual(TruSDXDemuxer.sampleToByte(1.0), 255)  // 1.0 * 127 + 128 = 255
    }

    /// sampleToByte must never return 0x3B (';')
    func testSampleToByteNeverReturnsSemicolon() {
        // Sweep all possible float inputs to verify 0x3B is never output
        for i in 0...255 {
            let sample = (Float(i) - 128.0) / 128.0
            let byte = TruSDXDemuxer.sampleToByte(sample)
            XCTAssertNotEqual(byte, 0x3B, "sampleToByte returned 0x3B for input \(sample)")
        }
    }

    /// Round-trip: byte → sample → byte should preserve value (except 0x3B → 0x3C)
    func testByteRoundTrip() {
        for i in 0...255 {
            let byte = UInt8(i)
            let sample = TruSDXDemuxer.byteToSample(byte)
            let recovered = TruSDXDemuxer.sampleToByte(sample)

            if byte == 0x3B {
                // The firmware sends 0x3C instead of 0x3B, so round-trip gives 0x3C
                XCTAssertEqual(recovered, 0x3C)
            } else {
                XCTAssertEqual(recovered, byte, accuracy: 1,
                    "Round-trip failed for byte \(byte): got \(recovered)")
            }
        }
    }

    // MARK: - Resampling

    func testUpsampleRatio() {
        let input: [Float] = [0.0, 0.5, -0.5, 1.0]
        let output = TruSDXSerialAudio.upsample(input, from: 7812.5, to: 48000)
        let expectedCount = Int(Double(input.count) * (48000.0 / 7812.5))
        XCTAssertEqual(output.count, expectedCount)
    }

    func testDownsampleRatio() {
        let input = [Float](repeating: 0.5, count: 48000)
        let output = TruSDXSerialAudio.downsample(input, from: 48000, to: 7812.5)
        let expectedCount = Int(48000.0 / (48000.0 / 7812.5))
        XCTAssertEqual(output.count, expectedCount)
    }

    func testUpsamplePreservesConstant() {
        let input: [Float] = [Float](repeating: 0.75, count: 100)
        let output = TruSDXSerialAudio.upsample(input, from: 7812.5, to: 48000)
        for sample in output {
            XCTAssertEqual(sample, 0.75, accuracy: 0.01)
        }
    }

    func testDownsamplePreservesConstant() {
        let input = [Float](repeating: -0.25, count: 4800)
        let output = TruSDXSerialAudio.downsample(input, from: 48000, to: 7812.5)
        for sample in output {
            XCTAssertEqual(sample, -0.25, accuracy: 0.01)
        }
    }

    func testEmptyResample() {
        let up = TruSDXSerialAudio.upsample([], from: 7812.5, to: 48000)
        let down = TruSDXSerialAudio.downsample([], from: 48000, to: 7812.5)
        XCTAssertTrue(up.isEmpty)
        XCTAssertTrue(down.isEmpty)
    }

    // MARK: - Realistic Firmware Stream Simulation

    /// Simulate what the firmware actually sends:
    /// UA1; confirmation, then continuous US<audio>; blocks with occasional CAT responses
    func testRealisticFirmwareStream() {
        var data = Data()

        // Firmware responds to UA1; with confirmation
        data.append(contentsOf: Data("UA1;".utf8))

        // Then starts streaming: US<audio>;
        data.append(contentsOf: [UInt8(ascii: "U"), UInt8(ascii: "S")])

        // 50 audio samples (simulate receiver noise around center)
        for _ in 0..<50 {
            var byte = UInt8.random(in: 100...160)
            if byte == 0x3B { byte = 0x3C }
            data.append(byte)
        }

        // CAT poll interrupts (firmware sends ; to end audio, then response, then resumes)
        data.append(contentsOf: Data(";FA00007074000;".utf8))
        data.append(contentsOf: [UInt8(ascii: "U"), UInt8(ascii: "S")])

        // 30 more audio samples
        for _ in 0..<30 {
            var byte = UInt8.random(in: 100...160)
            if byte == 0x3B { byte = 0x3C }
            data.append(byte)
        }
        data.append(0x3B) // end

        let result = demuxer.process(data)

        XCTAssertEqual(result.audioSamples.count, 80) // 50 + 30
        XCTAssertEqual(result.catResponses.count, 2)   // UA1; + FA...;
        XCTAssertEqual(result.catResponses[0], "UA1;")
        XCTAssertEqual(result.catResponses[1], "FA00007074000;")

        // All audio samples should be in valid range
        for sample in result.audioSamples {
            XCTAssertGreaterThanOrEqual(sample, -1.0)
            XCTAssertLessThanOrEqual(sample, 1.0)
        }
    }

    /// Simulate the firmware behavior when a CAT command is received during streaming:
    /// streaming stops (;), CAT is processed, then streaming resumes (US...)
    func testStreamInterruptAndResume() {
        // Initial audio stream
        var chunk1 = Data([0x3B, UInt8(ascii: "U"), UInt8(ascii: "S")])
        chunk1.append(contentsOf: [UInt8](repeating: 0x80, count: 20))

        let r1 = demuxer.process(chunk1)
        XCTAssertEqual(r1.audioSamples.count, 20)

        // Firmware interrupts stream to process CAT
        let chunk2 = Data(";MD2;".utf8)
        let r2 = demuxer.process(chunk2)
        XCTAssertEqual(r2.catResponses.count, 1)
        XCTAssertEqual(r2.catResponses[0], "MD2;")

        // Firmware resumes streaming
        var chunk3 = Data([UInt8(ascii: "U"), UInt8(ascii: "S")])
        chunk3.append(contentsOf: [UInt8](repeating: 0xA0, count: 15))
        chunk3.append(0x3B)

        let r3 = demuxer.process(chunk3)
        XCTAssertEqual(r3.audioSamples.count, 15)
    }

    // MARK: - RadioProfile

    func testTruSDXProfile() {
        let profile = RadioProfile.trusdx
        XCTAssertEqual(profile.defaultHamlibModel, 2028) // TS-480
        XCTAssertEqual(profile.defaultBaudRate, 115200)
        XCTAssertTrue(profile.usesSerialAudio)
    }

    func testDigirigProfile() {
        let profile = RadioProfile.digirig
        XCTAssertEqual(profile.defaultHamlibModel, 0) // user selects
        XCTAssertEqual(profile.defaultBaudRate, 9600)
        XCTAssertFalse(profile.usesSerialAudio)
    }
}

// Helper for UInt8 accuracy comparison
extension XCTestCase {
    func XCTAssertEqual(_ a: UInt8, _ b: UInt8, accuracy: UInt8, _ message: String = "", file: StaticString = #file, line: UInt = #line) {
        let diff = a > b ? a - b : b - a
        XCTAssertTrue(diff <= accuracy, "\(a) != \(b) (accuracy \(accuracy)) \(message)", file: file, line: line)
    }
}
