/// Kreuzvalidierung des LZHUF-Codecs gegen Pat/wl2k-go Referenz-Testvektoren.
///
/// Die Testvektoren stammen direkt aus:
///   https://github.com/la5nta/wl2k-go/blob/master/lzhuf/lzhuf_test.go
///
/// Pat B2-Format: [CRC16 (2 Bytes)] [FileSize LE (4 Bytes)] [Compressed Data]
/// Unser Format:                     [FileSize LE (4 Bytes)] [Compressed Data]
///
/// Test-Strategie:
/// 1. DECODE: Pat-komprimierte Daten → unser Decoder → Vergleich mit Klartext
/// 2. ENCODE: Klartext → unser Encoder → unser Decoder → Roundtrip-Vergleich
/// 3. BIT-EXACT: Unser Encoder-Output == Pat Encoder-Output (byte-für-byte)

import XCTest
@testable import DigiFox

final class LZHUFReferenceTests: XCTestCase {

    // MARK: - Pat Testvektoren (aus wl2k-go/lzhuf/lzhuf_test.go)

    /// Pat B2 format: CRC16(2) + Size(4) + CompressedData
    /// Unser Format:             Size(4) + CompressedData
    /// → Wir strippen die ersten 2 Bytes (CRC16) für unseren Decoder.

    struct TestVector {
        let name: String
        let plain: Data
        let b2Compressed: [UInt8]  // Full Pat B2 format (with CRC16 prefix)

        /// Compressed data without CRC16 prefix (our format)
        var ourFormat: Data {
            Data(b2Compressed.dropFirst(2))
        }
    }

    static let vectors: [TestVector] = [
        TestVector(
            name: "newline",
            plain: Data("\n".utf8),
            b2Compressed: [0x0e, 0x8f, 0x01, 0x00, 0x00, 0x00, 0xcb, 0x00]
        ),
        TestVector(
            name: "foo",
            plain: Data("foo".utf8),
            b2Compressed: [0xb6, 0x47, 0x03, 0x00, 0x00, 0x00, 0xf9, 0x7e, 0xf1, 0x00]
        ),
        TestVector(
            name: "quick_brown_fox_x2",
            plain: Data("The quick brown fox jumps over the lazy dog\r\nThe quick brown fox jumps over the lazy dog".utf8),
            b2Compressed: [
                0x76, 0x25, 0x58, 0x00, 0x00, 0x00,
                0xf0, 0x7d, 0x3e, 0x3a, 0xcf, 0xe8, 0x0f, 0xd7,
                0xdf, 0xf7, 0xc2, 0xf7, 0x7f, 0xbf, 0x60, 0x7f,
                0xab, 0x7f, 0x2b, 0xa0, 0x4b, 0x7f, 0x6c, 0x0f,
                0xcf, 0xf3, 0xff, 0x55, 0x60, 0x2c, 0x3b, 0xba,
                0x80, 0x23, 0x03, 0xdf, 0x8f, 0x68, 0x30, 0x2d,
                0x3f, 0x0a, 0xff, 0x3c, 0xce, 0x5b, 0xf2, 0x2c,
            ]
        ),
        TestVector(
            name: "bar",
            plain: Data("bar".utf8),
            b2Compressed: [0xc7, 0xef, 0x03, 0x00, 0x00, 0x00, 0xf7, 0x7b, 0x7f, 0xc0]
        ),
    ]

    // MARK: - Test 1: Dekodierung von Pat-komprimierten Daten

    func testDecodePat_newline() { verifyDecode(vectors[0]) }
    func testDecodePat_foo() { verifyDecode(vectors[1]) }
    func testDecodePat_quickBrownFox() { verifyDecode(vectors[2]) }
    func testDecodePat_bar() { verifyDecode(vectors[3]) }

    private func verifyDecode(_ vector: TestVector) {
        let codec = LZHUFCodec()
        let decoded = codec.decompress(vector.ourFormat)

        XCTAssertEqual(decoded, vector.plain,
            "\(vector.name): Dekodierung stimmt nicht überein.\n" +
            "  Erwartet: \(String(data: vector.plain, encoding: .utf8) ?? "?")\n" +
            "  Erhalten: \(String(data: decoded, encoding: .utf8) ?? "?")\n" +
            "  Erwartet Hex: \(vector.plain.map { String(format: "%02x", $0) }.joined())\n" +
            "  Erhalten Hex: \(decoded.map { String(format: "%02x", $0) }.joined())")
    }

    // MARK: - Test 2: Roundtrip (eigener Encoder → eigener Decoder)

    func testRoundtrip_newline() { verifyRoundtrip(vectors[0]) }
    func testRoundtrip_foo() { verifyRoundtrip(vectors[1]) }
    func testRoundtrip_quickBrownFox() { verifyRoundtrip(vectors[2]) }
    func testRoundtrip_bar() { verifyRoundtrip(vectors[3]) }

    func testRoundtrip_empty() {
        let codec = LZHUFCodec()
        let compressed = codec.compress(Data())
        let decompressed = LZHUFCodec().decompress(compressed)
        XCTAssertEqual(decompressed, Data(), "Leere Daten Roundtrip")
    }

    func testRoundtrip_allBytes() {
        let codec = LZHUFCodec()
        var data = Data(count: 256)
        for i in 0..<256 { data[i] = UInt8(i) }
        let compressed = codec.compress(data)
        let decompressed = LZHUFCodec().decompress(compressed)
        XCTAssertEqual(decompressed, data, "Alle 256 Bytes Roundtrip")
    }

    func testRoundtrip_repetitive() {
        let codec = LZHUFCodec()
        let original = String(repeating: "ABCDEFGH", count: 200)
        let data = Data(original.utf8)
        let compressed = codec.compress(data)
        XCTAssertLessThan(compressed.count, data.count, "Repetitive Daten sollten komprimierbar sein")
        let decompressed = LZHUFCodec().decompress(compressed)
        XCTAssertEqual(decompressed, data, "Repetitive Daten Roundtrip")
    }

    func testRoundtrip_winlinkMessage() {
        let codec = LZHUFCodec()
        let message = """
        Mid: DL1ATEST01\r\n\
        From: DL1ABC@winlink.org\r\n\
        To: DL2XYZ@winlink.org\r\n\
        Subject: Test Nachricht\r\n\
        Date: 2024/01/15 12:00\r\n\
        Content-Type: text/plain\r\n\
        \r\n\
        Hallo, dies ist eine Test-Nachricht über Winlink.\r\n\
        73 de DL1ABC\r\n
        """
        let data = Data(message.utf8)
        let compressed = codec.compress(data)
        let decompressed = LZHUFCodec().decompress(compressed)
        XCTAssertEqual(decompressed, data, "Winlink-Nachricht Roundtrip")
    }

    private func verifyRoundtrip(_ vector: TestVector) {
        let codec = LZHUFCodec()
        let compressed = codec.compress(vector.plain)
        let decompressed = LZHUFCodec().decompress(compressed)

        XCTAssertEqual(decompressed, vector.plain,
            "\(vector.name): Roundtrip stimmt nicht überein.\n" +
            "  Original: \(String(data: vector.plain, encoding: .utf8) ?? "?")\n" +
            "  Nach Roundtrip: \(String(data: decompressed, encoding: .utf8) ?? "?")")
    }

    // MARK: - Test 3: Bit-exakter Vergleich mit Pat-Output

    func testBitExact_newline() { verifyBitExact(vectors[0]) }
    func testBitExact_foo() { verifyBitExact(vectors[1]) }
    func testBitExact_quickBrownFox() { verifyBitExact(vectors[2]) }
    func testBitExact_bar() { verifyBitExact(vectors[3]) }

    private func verifyBitExact(_ vector: TestVector) {
        let codec = LZHUFCodec()
        let ourCompressed = codec.compress(vector.plain)
        let patCompressed = vector.ourFormat

        // Size header (bytes 0-3) must match
        XCTAssertEqual(Array(ourCompressed.prefix(4)), Array(patCompressed.prefix(4)),
            "\(vector.name): Size-Header stimmt nicht überein.\n" +
            "  Unser: \(Array(ourCompressed.prefix(4)).map { String(format: "%02x", $0) }.joined())\n" +
            "  Pat:   \(Array(patCompressed.prefix(4)).map { String(format: "%02x", $0) }.joined())")

        // Compressed data should match
        let ourBytes = Array(ourCompressed.dropFirst(4))
        let patBytes = Array(patCompressed.dropFirst(4))

        if ourBytes != patBytes {
            // Find first mismatch
            let minLen = min(ourBytes.count, patBytes.count)
            for i in 0..<minLen {
                if ourBytes[i] != patBytes[i] {
                    XCTFail("\(vector.name): Komprimierte Daten weichen ab bei Byte \(i).\n" +
                        "  Unser Byte[\(i)]: 0x\(String(format: "%02x", ourBytes[i]))\n" +
                        "  Pat   Byte[\(i)]: 0x\(String(format: "%02x", patBytes[i]))\n" +
                        "  Unser (\(ourBytes.count) bytes): \(ourBytes.map { String(format: "%02x", $0) }.joined(separator: " "))\n" +
                        "  Pat   (\(patBytes.count) bytes): \(patBytes.map { String(format: "%02x", $0) }.joined(separator: " "))")
                    break
                }
            }
            if ourBytes.count != patBytes.count {
                XCTFail("\(vector.name): Länge unterschiedlich: unser=\(ourBytes.count), pat=\(patBytes.count)")
            }
        }
    }

    // MARK: - Test 4: Stress-Tests

    func testLargeData() {
        let codec = LZHUFCodec()
        // 10KB random-ish data
        var data = Data(count: 10240)
        for i in 0..<data.count {
            data[i] = UInt8((i * 7 + 13) & 0xFF)
        }
        let compressed = codec.compress(data)
        let decompressed = LZHUFCodec().decompress(compressed)
        XCTAssertEqual(decompressed, data, "10KB Roundtrip fehlgeschlagen")
    }

    func testSingleByte() {
        for b: UInt8 in [0x00, 0x20, 0x41, 0x7F, 0xFF] {
            let codec = LZHUFCodec()
            let data = Data([b])
            let compressed = codec.compress(data)
            let decompressed = LZHUFCodec().decompress(compressed)
            XCTAssertEqual(decompressed, data, "Single-Byte 0x\(String(format: "%02x", b)) Roundtrip")
        }
    }

    func testTwoBytesAllCombinations() {
        // Test a selection of 2-byte combinations
        let codec = LZHUFCodec()
        let testPairs: [(UInt8, UInt8)] = [
            (0, 0), (0, 1), (1, 0), (0xFF, 0xFF),
            (0x41, 0x42), (0x0D, 0x0A), (0x20, 0x20)
        ]
        for (a, b) in testPairs {
            let data = Data([a, b])
            let compressed = codec.compress(data)
            let decompressed = LZHUFCodec().decompress(compressed)
            XCTAssertEqual(decompressed, data,
                "2-Byte (0x\(String(format: "%02x", a)), 0x\(String(format: "%02x", b))) Roundtrip")
        }
    }
}
