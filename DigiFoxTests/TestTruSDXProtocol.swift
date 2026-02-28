#!/usr/bin/env swift
// TruSDX CAT_STREAMING Protocol Test Suite
// Run: swift DigiFoxTests/TestTruSDXProtocol.swift

import Foundation

// ============================================================
// Inline the TruSDXDemuxer (pure value type, no dependencies)
// ============================================================

struct TruSDXDemuxer {
    struct Result {
        var audioSamples: [Float]
        var catResponses: [String]
    }

    private enum State {
        case cat
        case semicolon
        case semicolonU
        case audio
    }

    private var state: State = .cat
    private var catBuffer = ""

    mutating func process(_ data: Data) -> Result {
        var audio = [Float]()
        var cat = [String]()

        for byte in data {
            switch state {
            case .cat:
                if byte == 0x3B {
                    if !catBuffer.isEmpty {
                        cat.append(catBuffer + ";")
                        catBuffer = ""
                    }
                    state = .semicolon
                } else {
                    catBuffer.append(Character(UnicodeScalar(byte)))
                }
            case .semicolon:
                if byte == UInt8(ascii: "U") {
                    state = .semicolonU
                } else {
                    catBuffer.append(Character(UnicodeScalar(byte)))
                    state = .cat
                }
            case .semicolonU:
                if byte == UInt8(ascii: "S") {
                    state = .audio
                } else {
                    catBuffer.append("U")
                    catBuffer.append(Character(UnicodeScalar(byte)))
                    state = .cat
                }
            case .audio:
                if byte == 0x3B {
                    state = .semicolon
                } else {
                    audio.append(Self.byteToSample(byte))
                }
            }
        }
        return Result(audioSamples: audio, catResponses: cat)
    }

    mutating func reset() {
        state = .cat
        catBuffer = ""
    }

    static func byteToSample(_ byte: UInt8) -> Float {
        (Float(byte) - 128.0) / 128.0
    }

    static func sampleToByte(_ sample: Float) -> UInt8 {
        let clamped = max(-1.0, min(1.0, sample))
        var byte = UInt8(clamped * 127.0 + 128.0)
        if byte == 0x3B { byte = 0x3C }
        return byte
    }
}

// Resampling (from TruSDXSerialAudio)
func upsample(_ samples: [Float], from sourceSR: Double, to targetSR: Double) -> [Float] {
    let ratio = targetSR / sourceSR
    let outputCount = Int(Double(samples.count) * ratio)
    guard outputCount > 0 else { return [] }
    var output = [Float](repeating: 0, count: outputCount)
    for i in 0..<outputCount {
        let srcIndex = Double(i) / ratio
        let idx = Int(srcIndex)
        let frac = Float(srcIndex - Double(idx))
        if idx + 1 < samples.count {
            output[i] = samples[idx] * (1.0 - frac) + samples[idx + 1] * frac
        } else if idx < samples.count {
            output[i] = samples[idx]
        }
    }
    return output
}

func downsample(_ samples: [Float], from sourceSR: Double, to targetSR: Double) -> [Float] {
    let ratio = sourceSR / targetSR
    let outputCount = Int(Double(samples.count) / ratio)
    guard outputCount > 0 else { return [] }
    var output = [Float](repeating: 0, count: outputCount)
    for i in 0..<outputCount {
        let srcIndex = Double(i) * ratio
        let idx = Int(srcIndex)
        let frac = Float(srcIndex - Double(idx))
        if idx + 1 < samples.count {
            output[i] = samples[idx] * (1.0 - frac) + samples[idx + 1] * frac
        } else if idx < samples.count {
            output[i] = samples[idx]
        }
    }
    return output
}

// ============================================================
// Test Framework
// ============================================================

var testsPassed = 0
var testsFailed = 0
var currentTest = ""

func test(_ name: String, _ body: () throws -> Void) {
    currentTest = name
    do {
        try body()
        testsPassed += 1
        print("  ✅ \(name)")
    } catch {
        testsFailed += 1
        print("  ❌ \(name): \(error)")
    }
}

struct AssertionError: Error, CustomStringConvertible {
    let description: String
}

func assertEqual<T: Equatable>(_ a: T, _ b: T, _ msg: String = "") throws {
    guard a == b else {
        throw AssertionError(description: "Expected \(b), got \(a). \(msg)")
    }
}

func assertEqualFloat(_ a: Float, _ b: Float, accuracy: Float = 0.01, _ msg: String = "") throws {
    guard abs(a - b) <= accuracy else {
        throw AssertionError(description: "Expected \(b) ± \(accuracy), got \(a). \(msg)")
    }
}

func assertTrue(_ condition: Bool, _ msg: String = "") throws {
    guard condition else { throw AssertionError(description: "Expected true. \(msg)") }
}

// ============================================================
// Tests
// ============================================================

print("╔══════════════════════════════════════════════════════╗")
print("║   TruSDX CAT_STREAMING Protocol Test Suite          ║")
print("╚══════════════════════════════════════════════════════╝")
print()

// ---- Section: Basic Audio ----
print("▸ Basic Audio Streaming")

test("Basic audio block (;US<samples>;)") {
    var d = TruSDXDemuxer()
    let data = Data([0x3B, UInt8(ascii: "U"), UInt8(ascii: "S"),
                     0x80, 0xA0, 0x60,
                     0x3B])
    let r = d.process(data)
    try assertEqual(r.audioSamples.count, 3)
    try assertEqualFloat(r.audioSamples[0], 0.0)      // 128 → 0.0
    try assertEqualFloat(r.audioSamples[1], 0.25)      // 160 → +0.25
    try assertEqualFloat(r.audioSamples[2], -0.25)     // 96  → -0.25
    try assertTrue(r.catResponses.isEmpty)
}

test("100 silence samples (0x80)") {
    var d = TruSDXDemuxer()
    let data = Data([0x3B, UInt8(ascii: "U"), UInt8(ascii: "S")]
        + [UInt8](repeating: 0x80, count: 100) + [0x3B])
    let r = d.process(data)
    try assertEqual(r.audioSamples.count, 100)
    for s in r.audioSamples { try assertEqualFloat(s, 0.0, accuracy: 0.001) }
}

test("Max positive sample (0xFF)") {
    var d = TruSDXDemuxer()
    let data = Data([0x3B, UInt8(ascii: "U"), UInt8(ascii: "S"), 0xFF, 0x3B])
    let r = d.process(data)
    try assertEqual(r.audioSamples.count, 1)
    try assertEqualFloat(r.audioSamples[0], 127.0/128.0, accuracy: 0.001)
}

test("Min sample (0x00) → -1.0") {
    var d = TruSDXDemuxer()
    let data = Data([0x3B, UInt8(ascii: "U"), UInt8(ascii: "S"), 0x00, 0x3B])
    let r = d.process(data)
    try assertEqual(r.audioSamples.count, 1)
    try assertEqualFloat(r.audioSamples[0], -1.0, accuracy: 0.001)
}

test("Semicolon avoidance: 0x3C decoded as audio, not delimiter") {
    var d = TruSDXDemuxer()
    let data = Data([0x3B, UInt8(ascii: "U"), UInt8(ascii: "S"), 0x3C, 0x80, 0x3B])
    let r = d.process(data)
    try assertEqual(r.audioSamples.count, 2)
    try assertEqualFloat(r.audioSamples[0], (60.0-128.0)/128.0, accuracy: 0.001)
    try assertEqualFloat(r.audioSamples[1], 0.0, accuracy: 0.001)
}

test("All 256 byte values in audio stream (except 0x3B)") {
    var d = TruSDXDemuxer()
    var data = Data([0x3B, UInt8(ascii: "U"), UInt8(ascii: "S")])
    var expectedCount = 0
    for i in 0...255 {
        if i != 0x3B { data.append(UInt8(i)); expectedCount += 1 }
    }
    data.append(0x3B)
    let r = d.process(data)
    try assertEqual(r.audioSamples.count, expectedCount)
    try assertTrue(r.catResponses.isEmpty)
}

// ---- Section: CAT Responses ----
print()
print("▸ CAT Responses")

test("Simple CAT response: FA00007074000;") {
    var d = TruSDXDemuxer()
    let r = d.process(Data("FA00007074000;".utf8))
    try assertTrue(r.audioSamples.isEmpty)
    try assertEqual(r.catResponses.count, 1)
    try assertEqual(r.catResponses[0], "FA00007074000;")
}

test("Multiple CAT responses: FA...;MD2;") {
    var d = TruSDXDemuxer()
    let r = d.process(Data("FA00007074000;MD2;".utf8))
    try assertEqual(r.catResponses.count, 2)
    try assertEqual(r.catResponses[0], "FA00007074000;")
    try assertEqual(r.catResponses[1], "MD2;")
}

test("UA1; confirmation") {
    var d = TruSDXDemuxer()
    let r = d.process(Data("UA1;".utf8))
    try assertEqual(r.catResponses.count, 1)
    try assertEqual(r.catResponses[0], "UA1;")
}

test("IF response (long)") {
    var d = TruSDXDemuxer()
    let ifResp = "IF00007074000     +00000000020000000;"
    let r = d.process(Data(ifResp.utf8))
    try assertEqual(r.catResponses.count, 1)
    try assertTrue(r.catResponses[0].hasPrefix("IF"))
}

test("ID; response") {
    var d = TruSDXDemuxer()
    let r = d.process(Data("ID020;".utf8))
    try assertEqual(r.catResponses.count, 1)
    try assertEqual(r.catResponses[0], "ID020;")
}

// ---- Section: Interleaved Audio + CAT ----
print()
print("▸ Interleaved Audio and CAT")

test("Audio → CAT → Audio") {
    var d = TruSDXDemuxer()
    var data = Data()
    data.append(contentsOf: [0x3B, UInt8(ascii: "U"), UInt8(ascii: "S")])
    data.append(contentsOf: [0x80, 0x80, 0x80])    // 3 audio
    data.append(contentsOf: [0x3B])                  // end audio
    data.append(contentsOf: Data("FA00007074000;".utf8))
    data.append(contentsOf: [UInt8(ascii: "U"), UInt8(ascii: "S")])
    data.append(contentsOf: [0xA0, 0xA0])           // 2 audio
    data.append(contentsOf: [0x3B])
    let r = d.process(data)
    try assertEqual(r.audioSamples.count, 5)
    try assertEqual(r.catResponses.count, 1)
    try assertEqual(r.catResponses[0], "FA00007074000;")
}

test("Multiple CAT between audio blocks") {
    var d = TruSDXDemuxer()
    var data = Data()
    data.append(contentsOf: [0x3B, UInt8(ascii: "U"), UInt8(ascii: "S"), 0x80, 0x80])
    data.append(contentsOf: Data(";FA00007074000;MD2;".utf8))
    data.append(contentsOf: [UInt8(ascii: "U"), UInt8(ascii: "S"), 0xC0, 0x3B])
    let r = d.process(data)
    try assertEqual(r.audioSamples.count, 3)
    try assertEqual(r.catResponses.count, 2)
    try assertEqual(r.catResponses[0], "FA00007074000;")
    try assertEqual(r.catResponses[1], "MD2;")
}

test("Consecutive audio blocks (no CAT in between)") {
    var d = TruSDXDemuxer()
    var data = Data()
    data.append(contentsOf: [0x3B, UInt8(ascii: "U"), UInt8(ascii: "S"), 0x80, 0x80, 0x80])
    data.append(contentsOf: [0x3B, UInt8(ascii: "U"), UInt8(ascii: "S"), 0xA0, 0xA0])
    data.append(0x3B)
    let r = d.process(data)
    try assertEqual(r.audioSamples.count, 5)
    try assertTrue(r.catResponses.isEmpty)
}

// ---- Section: State Machine Edge Cases ----
print()
print("▸ State Machine Edge Cases")

test("Byte-by-byte processing") {
    var d = TruSDXDemuxer()
    let bytes: [UInt8] = [0x3B, UInt8(ascii: "U"), UInt8(ascii: "S"), 0x80, 0xA0, 0x3B]
    var totalAudio = [Float]()
    for byte in bytes {
        let r = d.process(Data([byte]))
        totalAudio.append(contentsOf: r.audioSamples)
    }
    try assertEqual(totalAudio.count, 2)
    try assertEqualFloat(totalAudio[0], 0.0)
    try assertEqualFloat(totalAudio[1], 0.25)
}

test(";UD (display cmd) is NOT audio") {
    var d = TruSDXDemuxer()
    let data = Data(";UD0116chars here ;".utf8)
    let r = d.process(data)
    try assertTrue(r.audioSamples.isEmpty)
    try assertEqual(r.catResponses.count, 1)
    try assertTrue(r.catResponses[0].hasPrefix("UD"))
}

test(";UK (key cmd) is NOT audio") {
    var d = TruSDXDemuxer()
    let data = Data(";UK01;".utf8)
    let r = d.process(data)
    try assertTrue(r.audioSamples.isEmpty)
    try assertEqual(r.catResponses.count, 1)
    try assertEqual(r.catResponses[0], "UK01;")
}

test(";U split across chunks") {
    var d = TruSDXDemuxer()
    let r1 = d.process(Data([0x3B, UInt8(ascii: "U")]))
    let r2 = d.process(Data([UInt8(ascii: "S"), 0x80, 0x80, 0x3B]))
    try assertTrue(r1.audioSamples.isEmpty)
    try assertEqual(r2.audioSamples.count, 2)
}

test("; split across chunks") {
    var d = TruSDXDemuxer()
    let r1 = d.process(Data([0x3B]))
    let r2 = d.process(Data([UInt8(ascii: "U"), UInt8(ascii: "S"), 0xC0, 0x3B]))
    try assertTrue(r1.audioSamples.isEmpty)
    try assertEqual(r2.audioSamples.count, 1)
    try assertEqualFloat(r2.audioSamples[0], (192.0-128.0)/128.0, accuracy: 0.001)
}

test("Empty data → empty results") {
    var d = TruSDXDemuxer()
    let r = d.process(Data())
    try assertTrue(r.audioSamples.isEmpty)
    try assertTrue(r.catResponses.isEmpty)
}

test("Reset clears partial state") {
    var d = TruSDXDemuxer()
    _ = d.process(Data("FA0000".utf8))
    d.reset()
    let r = d.process(Data("MD2;".utf8))
    try assertEqual(r.catResponses.count, 1)
    try assertEqual(r.catResponses[0], "MD2;")
}

test("Long audio stream (1000 samples)") {
    var d = TruSDXDemuxer()
    var data = Data([0x3B, UInt8(ascii: "U"), UInt8(ascii: "S")])
    for i in 0..<1000 {
        var byte = UInt8(i % 256)
        if byte == 0x3B { byte = 0x3C }
        data.append(byte)
    }
    data.append(0x3B)
    let r = d.process(data)
    try assertEqual(r.audioSamples.count, 1000)
    try assertTrue(r.catResponses.isEmpty)
}

test("Audio with all non-semicolon bytes (255 values)") {
    var d = TruSDXDemuxer()
    var data = Data([0x3B, UInt8(ascii: "U"), UInt8(ascii: "S")])
    var count = 0
    for i in 0...255 where i != 0x3B {
        data.append(UInt8(i))
        count += 1
    }
    data.append(0x3B)
    let r = d.process(data)
    try assertEqual(r.audioSamples.count, count) // 255 samples
}

// ---- Section: Byte ↔ Sample Conversion ----
print()
print("▸ Byte ↔ Sample Conversion")

test("byteToSample known values") {
    try assertEqualFloat(TruSDXDemuxer.byteToSample(128), 0.0, accuracy: 0.001)
    try assertEqualFloat(TruSDXDemuxer.byteToSample(0), -1.0, accuracy: 0.001)
    try assertEqualFloat(TruSDXDemuxer.byteToSample(255), 127.0/128.0, accuracy: 0.001)
    try assertEqualFloat(TruSDXDemuxer.byteToSample(64), -0.5, accuracy: 0.001)
    try assertEqualFloat(TruSDXDemuxer.byteToSample(192), 0.5, accuracy: 0.001)
}

test("sampleToByte known values") {
    try assertEqual(TruSDXDemuxer.sampleToByte(0.0), 128)
    try assertEqual(TruSDXDemuxer.sampleToByte(-1.0), 1)
    try assertEqual(TruSDXDemuxer.sampleToByte(1.0), 255)
}

test("sampleToByte clamps out-of-range") {
    try assertEqual(TruSDXDemuxer.sampleToByte(-2.0), 1)
    try assertEqual(TruSDXDemuxer.sampleToByte(5.0), 255)
}

test("sampleToByte NEVER returns 0x3B (semicolon)") {
    for i in 0...255 {
        let sample = (Float(i) - 128.0) / 128.0
        let byte = TruSDXDemuxer.sampleToByte(sample)
        try assertTrue(byte != 0x3B, "sampleToByte returned 0x3B for input \(sample)")
    }
    // Also test fine-grained sweep
    var s: Float = -1.0
    while s <= 1.0 {
        let byte = TruSDXDemuxer.sampleToByte(s)
        try assertTrue(byte != 0x3B, "sampleToByte returned 0x3B for input \(s)")
        s += 0.001
    }
}

test("Byte round-trip (byte→sample→byte)") {
    for i in 0...255 {
        let byte = UInt8(i)
        let sample = TruSDXDemuxer.byteToSample(byte)
        let recovered = TruSDXDemuxer.sampleToByte(sample)
        if byte == 0x3B {
            try assertEqual(recovered, 0x3C) // firmware avoids 0x3B
        } else {
            let diff = Int(recovered) - Int(byte)
            try assertTrue(abs(diff) <= 1, "Round-trip failed for byte \(byte): got \(recovered)")
        }
    }
}

// ---- Section: Resampling ----
print()
print("▸ Resampling")

test("Upsample ratio 7812.5 → 48000") {
    let input: [Float] = [0.0, 0.5, -0.5, 1.0]
    let output = upsample(input, from: 7812.5, to: 48000)
    let expected = Int(Double(input.count) * (48000.0 / 7812.5))
    try assertEqual(output.count, expected)
}

test("Downsample ratio 48000 → 7812.5") {
    let input = [Float](repeating: 0.5, count: 48000)
    let output = downsample(input, from: 48000, to: 7812.5)
    let expected = Int(48000.0 / (48000.0 / 7812.5))
    try assertEqual(output.count, expected)
}

test("Upsample preserves DC signal") {
    let input = [Float](repeating: 0.75, count: 100)
    let output = upsample(input, from: 7812.5, to: 48000)
    for s in output { try assertEqualFloat(s, 0.75, accuracy: 0.01) }
}

test("Downsample preserves DC signal") {
    let input = [Float](repeating: -0.25, count: 4800)
    let output = downsample(input, from: 48000, to: 7812.5)
    for s in output { try assertEqualFloat(s, -0.25, accuracy: 0.01) }
}

test("Empty resample") {
    try assertTrue(upsample([], from: 7812.5, to: 48000).isEmpty)
    try assertTrue(downsample([], from: 48000, to: 7812.5).isEmpty)
}

test("Upsample for 16MHz board (6250 → 48000)") {
    let input = [Float](repeating: 0.5, count: 50)
    let output = upsample(input, from: 6250.0, to: 48000)
    let expected = Int(Double(50) * (48000.0 / 6250.0))
    try assertEqual(output.count, expected)
    for s in output { try assertEqualFloat(s, 0.5, accuracy: 0.01) }
}

// ---- Section: Realistic Firmware Simulation ----
print()
print("▸ Realistic Firmware Simulation")

test("Full firmware startup sequence") {
    var d = TruSDXDemuxer()
    var data = Data()
    // Firmware responds to UA1; with confirmation
    data.append(contentsOf: Data("UA1;".utf8))
    // Then starts streaming
    data.append(contentsOf: [UInt8(ascii: "U"), UInt8(ascii: "S")])
    // 50 audio samples
    for _ in 0..<50 {
        var byte = UInt8.random(in: 100...160)
        if byte == 0x3B { byte = 0x3C }
        data.append(byte)
    }
    // CAT poll interrupts
    data.append(contentsOf: Data(";FA00007074000;".utf8))
    data.append(contentsOf: [UInt8(ascii: "U"), UInt8(ascii: "S")])
    // 30 more audio samples
    for _ in 0..<30 {
        var byte = UInt8.random(in: 100...160)
        if byte == 0x3B { byte = 0x3C }
        data.append(byte)
    }
    data.append(0x3B)

    let r = d.process(data)
    try assertEqual(r.audioSamples.count, 80)
    try assertEqual(r.catResponses.count, 2)
    try assertEqual(r.catResponses[0], "UA1;")
    try assertEqual(r.catResponses[1], "FA00007074000;")
    for s in r.audioSamples {
        try assertTrue(s >= -1.0 && s <= 1.0, "Sample out of range: \(s)")
    }
}

test("Stream interrupt and resume across chunks") {
    var d = TruSDXDemuxer()

    // Chunk 1: audio stream starts
    var c1 = Data([0x3B, UInt8(ascii: "U"), UInt8(ascii: "S")])
    c1.append(contentsOf: [UInt8](repeating: 0x80, count: 20))
    let r1 = d.process(c1)
    try assertEqual(r1.audioSamples.count, 20)

    // Chunk 2: firmware interrupts for CAT
    let r2 = d.process(Data(";MD2;".utf8))
    try assertEqual(r2.catResponses.count, 1)
    try assertEqual(r2.catResponses[0], "MD2;")

    // Chunk 3: firmware resumes streaming
    var c3 = Data([UInt8(ascii: "U"), UInt8(ascii: "S")])
    c3.append(contentsOf: [UInt8](repeating: 0xA0, count: 15))
    c3.append(0x3B)
    let r3 = d.process(c3)
    try assertEqual(r3.audioSamples.count, 15)
}

test("Rapid CAT polling during stream (FA/MD every 50 samples)") {
    var d = TruSDXDemuxer()
    var data = Data()
    var expectedAudio = 0

    // Start stream
    data.append(contentsOf: Data("UA1;".utf8))

    for _ in 0..<5 {
        // Audio block
        data.append(contentsOf: [UInt8(ascii: "U"), UInt8(ascii: "S")])
        for _ in 0..<50 {
            var byte = UInt8.random(in: 0...255)
            if byte == 0x3B { byte = 0x3C }
            data.append(byte)
        }
        expectedAudio += 50
        // CAT interrupt
        data.append(contentsOf: Data(";FA00007074000;".utf8))
    }

    let r = d.process(data)
    try assertEqual(r.audioSamples.count, expectedAudio)
    // UA1; + 5× FA...;
    try assertEqual(r.catResponses.count, 6)
}

test("Simulated 1 second of audio at 7812.5 Hz") {
    var d = TruSDXDemuxer()
    let samplesPerSecond = 7812
    var data = Data([0x3B, UInt8(ascii: "U"), UInt8(ascii: "S")])

    // Generate a sine wave
    for i in 0..<samplesPerSecond {
        let t = Float(i) / Float(samplesPerSecond)
        let sinVal = sin(2.0 * Float.pi * 1000.0 * t) // 1 kHz tone
        var byte = UInt8(sinVal * 127.0 + 128.0)
        if byte == 0x3B { byte = 0x3C }
        data.append(byte)
    }
    data.append(0x3B)

    let r = d.process(data)
    try assertEqual(r.audioSamples.count, samplesPerSecond)
    try assertTrue(r.catResponses.isEmpty)

    // Verify range
    let minSample = r.audioSamples.min()!
    let maxSample = r.audioSamples.max()!
    try assertTrue(minSample < -0.9, "Sine wave min too high: \(minSample)")
    try assertTrue(maxSample > 0.9, "Sine wave max too low: \(maxSample)")
}

// ============================================================
// Summary
// ============================================================
print()
print("══════════════════════════════════════════════════════")
let total = testsPassed + testsFailed
if testsFailed == 0 {
    print("✅ All \(total) tests passed!")
} else {
    print("❌ \(testsFailed) of \(total) tests FAILED")
}
print("══════════════════════════════════════════════════════")

exit(testsFailed > 0 ? 1 : 0)
