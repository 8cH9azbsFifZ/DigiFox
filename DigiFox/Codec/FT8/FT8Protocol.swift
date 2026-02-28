import Foundation

/// FT8 protocol constants and timing parameters.
/// FT8 uses 8-FSK modulation with 79 symbols per frame,
/// synchronized to 15-second TX windows via Costas arrays.
enum FT8Protocol {

    // MARK: - Audio & Modulation

    static let sampleRate: Double = 12_000
    static let symbolSamples: Int = 1_920          // 0.16s × 12000
    static let symbolDuration: Double = 0.16       // seconds
    static let toneSpacing: Double = 6.25          // Hz
    static let toneCount: Int = 8                  // 8-FSK

    // MARK: - Frame Structure

    static let symbolCount: Int = 79
    static let costasLength: Int = 7
    static let dataSymbolCount: Int = 58           // 79 − 3×7

    // MARK: - Coding

    static let codedBits: Int = 174                // LDPC codeword length
    static let messageBits: Int = 91               // 77 payload + 14 CRC
    static let payloadBits: Int = 77
    static let crcBits: Int = 14
    static let bitsPerSymbol: Int = 3              // log2(8)

    // MARK: - Timing

    static let txWindow: Double = 15.0             // seconds
    static let frameSamples: Int = symbolCount * symbolSamples   // 151680

    // MARK: - Costas Array

    /// 7-element Costas array used for synchronization.
    static let costas: [Int] = [3, 1, 4, 0, 6, 5, 2]

    // MARK: - Symbol Positions

    /// Sync symbol positions within the 79-symbol frame:
    /// Costas at [0‥6], [36‥42], [72‥78].
    static let syncPositions: [Int] = {
        var p = [Int]()
        for i in 0...6 { p.append(i) }
        for i in 36...42 { p.append(i) }
        for i in 72...78 { p.append(i) }
        return p
    }()

    /// Data symbol positions (all non-sync positions).
    static let dataPositions: [Int] = {
        let syncSet = Set(syncPositions)
        return (0..<symbolCount).filter { !syncSet.contains($0) }
    }()

    // MARK: - Callsign Encoding

    static let ntokens: UInt32 = 268_435_456       // 2^28
    static let cqToken: UInt32 = ntokens - 2

    // MARK: - Gray Code Tables

    /// Maps 3-bit natural binary to Gray code (for symbol mapping).
    static let grayEncode: [Int] = [0, 1, 3, 2, 6, 7, 5, 4]
    /// Maps 3-bit Gray code back to natural binary.
    static let grayDecode: [Int] = {
        var table = [Int](repeating: 0, count: 8)
        for i in 0..<8 { table[grayEncode[i]] = i }
        return table
    }()
}
