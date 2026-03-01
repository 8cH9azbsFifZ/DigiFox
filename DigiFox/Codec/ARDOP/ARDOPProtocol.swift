import Foundation

/// ARDOP (Amateur Radio Digital Open Protocol) constants and parameters.
///
/// ARDOP is an open-source ARQ protocol for reliable data transfer over HF radio.
/// It supports multiple bandwidth modes (200 Hz–2000 Hz) with adaptive modulation
/// (4FSK, 4PSK, 8PSK, 16QAM) and OFDM multi-carrier operation.
///
/// Reference implementation: https://github.com/pflarue/ardop
/// Protocol specification: https://ardop.groups.io/
/// Winlink client (Pat): https://github.com/la5nta/pat
///
/// Key characteristics:
///   - 12 kHz sample rate (matches DigiFox audio engine)
///   - ARQ with adaptive modulation based on channel quality
///   - Reed-Solomon FEC over GF(256)
///   - Two-tone leader for AGC settling and synchronization
///   - Used as the physical layer for Winlink email over HF
enum ARDOPProtocol {

    // MARK: - Audio

    /// Sample rate matches the DigiFox audio engine (12 kHz)
    static let sampleRate: Double = 12_000
    /// Center frequency for all ARDOP signals (Hz)
    static let centerFrequency: Double = 1500.0

    // MARK: - Leader

    /// Two-tone leader for AGC settling and frame synchronization.
    /// Tones are symmetric around the center frequency.
    static let leaderTone1: Double = 1475.0    // center − 25 Hz
    static let leaderTone2: Double = 1525.0    // center + 25 Hz
    /// Leader duration per tone (ms)
    static let leaderToneDurationMs: Double = 80.0
    /// Total leader duration (ms): two tones back-to-back
    static let leaderTotalDurationMs: Double = 160.0
    /// Leader samples per tone
    static let leaderToneSamples: Int = Int(leaderToneDurationMs / 1000.0 * sampleRate)
    /// Total leader samples
    static let leaderTotalSamples: Int = Int(leaderTotalDurationMs / 1000.0 * sampleRate)

    // MARK: - Frame Type Header

    /// Frame type byte is always sent as 2-carrier 50-baud 4FSK.
    /// 4 symbols encode the byte (2 bits/symbol), repeated once for reliability.
    static let frameTypeBaud: Double = 50.0
    static let frameTypeSymbolSamples: Int = Int(sampleRate / 50.0)  // 240
    /// 4 symbols × 2 (original + repeat) = 8 symbols total
    static let frameTypeSymbolCount: Int = 8
    static let frameTypeCarrier1: Double = 1475.0
    static let frameTypeCarrier2: Double = 1525.0
    /// Tone spacing for frame type header FSK
    static let frameTypeToneSpacing: Double = 50.0

    // MARK: - Symbol Rates

    static let baud50: Double = 50.0
    static let baud100: Double = 100.0
    static let baud600: Double = 600.0

    // MARK: - Tone Spacing for FSK Modes

    /// 4FSK tone spacing = symbol rate in Hz (orthogonal spacing)
    static func fskToneSpacing(for baudRate: Double) -> Double { baudRate }

    // MARK: - Carrier Configurations

    /// Single-carrier 200 Hz bandwidth
    static let carriers200Hz: [Double] = [1500.0]
    /// 2-carrier 500 Hz bandwidth (200 Hz carrier spacing)
    static let carriers500Hz: [Double] = [1400.0, 1600.0]
    /// 4-carrier 1000 Hz bandwidth
    static let carriers1000Hz: [Double] = [1200.0, 1400.0, 1600.0, 1800.0]
    /// 8-carrier 2000 Hz bandwidth
    static let carriers2000Hz: [Double] = [
        800.0, 1000.0, 1200.0, 1400.0, 1600.0, 1800.0, 2000.0, 2200.0
    ]

    // MARK: - Amplitude Ramp

    /// Raised-cosine ramp duration at frame start/end to avoid click artifacts
    static let rampMs: Double = 3.0
    static let rampSamples: Int = Int(rampMs / 1000.0 * sampleRate)  // 36

    // MARK: - Reed-Solomon

    /// GF(256) primitive polynomial: x⁸ + x⁴ + x³ + x² + 1
    static let rsPrimitive: Int = 0x11D
    static let rsFieldSize: Int = 256

    // MARK: - PSK/QAM Constellation Points

    /// DQPSK constellation: π/4 offset Gray-coded
    static let psk4Phases: [Double] = [
        .pi / 4.0,       // 00
        3.0 * .pi / 4.0, // 01
        5.0 * .pi / 4.0, // 11
        7.0 * .pi / 4.0  // 10
    ]

    /// D8PSK constellation: Gray-coded
    static let psk8Phases: [Double] = (0..<8).map { i in
        Double(i) * .pi / 4.0
    }

    /// 16QAM constellation (I, Q) — Gray-coded, normalized
    static let qam16Points: [(Double, Double)] = {
        let levels: [Double] = [-3.0, -1.0, 1.0, 3.0]
        let norm = 1.0 / sqrt(10.0)  // normalize average power to 1
        var points = [(Double, Double)]()
        // Gray-code ordering for 4-bit symbols
        let grayMap = [0, 1, 3, 2]
        for qi in 0..<4 {
            for ii in 0..<4 {
                points.append((levels[grayMap[ii]] * norm, levels[grayMap[qi]] * norm))
            }
        }
        return points
    }()

    // MARK: - Timing

    /// Maximum frame duration including leader + header + data (ms)
    static let maxFrameDurationMs: Double = 1200.0
}
