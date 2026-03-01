import Foundation

/// Generates keyed CW audio tone for transmission via USB audio interface.
///
/// Instead of toggling PTT for each dot/dash (too slow over CAT serial),
/// this generates a complete audio buffer with the CW signal — a sine wave
/// keyed on/off with proper morse timing and raised-cosine ramps to avoid
/// clicks. The buffer is then played through AudioEngine.transmit() with
/// the rig in USB mode, just like FT8/JS8.
///
/// References:
///  - PARIS standard timing: dot = 1200ms / WPM
///  - ITU-R M.1677 for morse code timing
struct CWToneGenerator {

    /// Audio sample rate (matches DigiFox audio pipeline)
    static let sampleRate: Double = 12_000.0

    /// Default CW sidetone frequency in Hz
    static let defaultToneFrequency: Double = 700.0

    /// Raised-cosine ramp duration in seconds (avoids key clicks)
    static let rampDuration: Double = 0.005

    /// Generate a complete audio buffer for the given morse text.
    /// - Parameters:
    ///   - text: Text to encode as morse (uppercase recommended)
    ///   - wpm: Speed in words per minute (PARIS standard)
    ///   - toneFrequency: Sidetone frequency in Hz (default 700)
    ///   - amplitude: Signal amplitude 0.0–1.0
    /// - Returns: Float sample array at 12 kHz, ready for AudioEngine.transmit()
    static func generate(
        text: String,
        wpm: Int,
        toneFrequency: Double = defaultToneFrequency,
        amplitude: Double = 0.8
    ) -> [Float] {
        let dot = 1.2 / Double(max(wpm, 5))
        let sps = sampleRate
        let rampSamples = Int(rampDuration * sps)

        // Build timing segments: [(duration, isTone)]
        var segments = [(Double, Bool)]()
        let chars = Array(text.uppercased())

        for (ci, char) in chars.enumerated() {
            if char == " " {
                segments.append((7.0 * dot, false))
                continue
            }
            guard let code = MorseKeyer.morseTable[char] else { continue }

            for (ei, element) in code.enumerated() {
                let dur = element == "-" ? 3.0 * dot : dot
                segments.append((dur, true))   // tone on
                if ei < code.count - 1 {
                    segments.append((dot, false)) // inter-element gap
                }
            }

            if ci < chars.count - 1 && chars[ci + 1] != " " {
                segments.append((3.0 * dot, false)) // inter-character gap
            }
        }

        // Calculate total sample count
        let totalDuration = segments.reduce(0.0) { $0 + $1.0 }
        let totalSamples = Int(totalDuration * sps) + 1
        guard totalSamples > 0 else { return [] }

        var samples = [Float](repeating: 0, count: totalSamples)
        var phase: Double = 0
        let phaseIncrement = 2.0 * .pi * toneFrequency / sps
        var sampleIdx = 0

        for (duration, isTone) in segments {
            let segSamples = Int(duration * sps)

            for j in 0..<segSamples {
                guard sampleIdx < totalSamples else { break }

                if isTone {
                    var env = amplitude

                    // Raised-cosine ramp up at segment start
                    if j < rampSamples {
                        env *= 0.5 * (1.0 - cos(.pi * Double(j) / Double(rampSamples)))
                    }
                    // Raised-cosine ramp down at segment end
                    let fromEnd = segSamples - 1 - j
                    if fromEnd < rampSamples {
                        env *= 0.5 * (1.0 - cos(.pi * Double(fromEnd) / Double(rampSamples)))
                    }

                    samples[sampleIdx] = Float(sin(phase) * env)
                }

                // Always advance phase (continuous even during silence)
                phase += phaseIncrement
                if phase >= 2.0 * .pi { phase -= 2.0 * .pi }
                sampleIdx += 1
            }
        }

        return Array(samples.prefix(sampleIdx))
    }
}
