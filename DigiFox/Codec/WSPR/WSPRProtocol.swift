import Foundation

/// WSPR protocol constants and timing parameters.
///
/// WSPR uses 4-FSK modulation with 162 symbols per frame,
/// synchronized to 2-minute TX windows (even minutes UTC).
///
/// Key differences from FT8:
///   - 4-FSK (not 8-FSK)
///   - 162 symbols (not 79)
///   - ~110.6 second TX duration (not 12.8s)
///   - 1.4648 Hz tone spacing (not 6.25 Hz)
///   - ~6 Hz total bandwidth (not 50 Hz)
///   - (50,32) convolutional code (not LDPC)
///   - Interleaved with pseudo-random sync vector
enum WSPRProtocol {

    // MARK: - Audio & Modulation

    static let sampleRate: Double = 12_000
    /// Samples per symbol: 8192 samples = 0.6827 seconds at 12 kHz
    static let symbolSamples: Int = 8_192
    static let symbolDuration: Double = Double(symbolSamples) / sampleRate  // ~0.6827s
    /// Tone spacing: 12000/8192 = 1.4648 Hz
    static let toneSpacing: Double = sampleRate / Double(symbolSamples)
    static let toneCount: Int = 4   // 4-FSK

    // MARK: - Frame Structure

    static let symbolCount: Int = 162

    // MARK: - Coding

    /// WSPR message: 50 bits (callsign 28 + grid 15 + power 7)
    static let messageBits: Int = 50
    /// After convolutional encoding: 162 coded bits (rate 1/2, K=32, but with tail → 162)
    static let codedBits: Int = 162

    // MARK: - Timing

    /// TX window: 120 seconds (2 minutes, even-minute start)
    static let txWindow: Double = 120.0
    /// Actual TX duration: 162 * 8192/12000 = ~110.6 seconds
    static let frameDuration: Double = Double(symbolCount) * symbolDuration
    static let frameSamples: Int = symbolCount * symbolSamples

    // MARK: - Sync Vector

    /// 162-bit pseudo-random sync vector for WSPR.
    /// Sync bits are interleaved with data: channel symbol = sync[i] + 2*data[i]
    static let syncVector: [Int] = [
        1,1,0,0,0,0,0,0,1,0,0,0,1,1,1,0,0,0,1,0,
        0,1,0,1,1,1,1,0,0,0,0,0,0,0,1,0,0,1,0,1,
        0,0,0,0,0,0,1,0,1,1,0,0,1,1,0,1,0,0,0,1,
        1,0,1,0,0,0,0,1,1,0,1,0,1,0,1,0,1,0,0,1,
        0,0,1,0,1,1,0,0,0,1,1,0,1,0,1,0,0,0,1,0,
        0,0,0,0,1,0,0,1,0,0,1,1,1,0,1,1,0,0,1,1,
        0,1,0,0,0,1,1,1,0,0,0,0,0,1,0,1,0,0,1,1,
        0,0,0,0,0,0,0,1,1,0,1,0,1,1,0,0,0,1,1,0,
        0,0
    ]

    // MARK: - Convolutional Code

    /// Generator polynomials for the K=32, rate 1/2 convolutional code
    static let poly1: UInt32 = 0xF2D05351
    static let poly2: UInt32 = 0xE4613C47

    // MARK: - Interleaver

    /// Bit-reversal interleaver for 256 positions (only first 162 used)
    static func interleaveIndex(_ i: Int) -> Int {
        var j = i
        var result = 0
        for _ in 0..<8 {
            result = (result << 1) | (j & 1)
            j >>= 1
        }
        return result
    }
}
