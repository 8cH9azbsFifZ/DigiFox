import Foundation

/// Software Morse keyer for (tr)uSDX.
///
/// The TruSDX does not support the Kenwood KY command for CW text.
/// Instead, CW is keyed by toggling TX0;/RX; with proper timing.
/// Mode must be set to CW (MD3;) first.
///
/// Timing: dot = 1200/WPM ms, dash = 3×dot, inter-element = dot,
/// inter-char = 3×dot, inter-word = 7×dot.
actor MorseKeyer {

    private var isKeying = false
    private var shouldStop = false

    /// Morse code lookup table
    static let morseTable: [Character: String] = [
        "A": ".-",    "B": "-...",  "C": "-.-.",  "D": "-..",
        "E": ".",     "F": "..-.",  "G": "--.",   "H": "....",
        "I": "..",    "J": ".---",  "K": "-.-",   "L": ".-..",
        "M": "--",    "N": "-.",    "O": "---",   "P": ".--.",
        "Q": "--.-",  "R": ".-.",   "S": "...",   "T": "-",
        "U": "..-",   "V": "...-",  "W": ".--",   "X": "-..-",
        "Y": "-.--",  "Z": "--..",
        "0": "-----", "1": ".----", "2": "..---", "3": "...--",
        "4": "....-", "5": ".....", "6": "-....", "7": "--...",
        "8": "---..", "9": "----.",
        "/": "-..-.", "=": "-...-", "?": "..--..", ".": ".-.-.-",
        ",": "--..--", "+": ".-.-.",  "-": "-....-",
        "@": ".--.-.", "!": "-.-.--",
    ]

    /// Key a text string as Morse code using PTT on/off.
    /// Uses PARIS standard: 20 WPM = dot duration 60ms.
    func key(text: String, wpm: Int, pttOn: @escaping () async throws -> Void, pttOff: @escaping () async throws -> Void) async {
        guard !isKeying else { return }
        isKeying = true
        shouldStop = false

        // PARIS standard: dot duration = 1200ms / WPM
        let dotDuration: UInt64 = UInt64(1_200_000_000 / max(wpm, 5)) // nanoseconds

        let chars = Array(text.uppercased())
        for (ci, char) in chars.enumerated() {
            if shouldStop { break }

            if char == " " {
                // Inter-word gap: 7 dots total. 3-dot inter-char gap already elapsed,
                // so wait 4 more dots.
                try? await Task.sleep(nanoseconds: 4 * dotDuration)
                continue
            }

            guard let code = Self.morseTable[char] else { continue }

            for (ei, element) in code.enumerated() {
                if shouldStop { break }

                let elementDuration: UInt64 = element == "-" ? 3 * dotDuration : dotDuration

                // Measure time spent in pttOn call to compensate for serial latency
                let t0 = ContinuousClock.now
                try? await pttOn()
                let pttOnElapsed = ContinuousClock.now - t0
                let pttOnNs = UInt64(pttOnElapsed.components.attoseconds / 1_000_000_000)

                // Sleep remaining element duration (subtract pttOn latency)
                if elementDuration > pttOnNs {
                    try? await Task.sleep(nanoseconds: elementDuration - pttOnNs)
                }

                // Key up
                let t1 = ContinuousClock.now
                try? await pttOff()
                let pttOffElapsed = ContinuousClock.now - t1
                let pttOffNs = UInt64(pttOffElapsed.components.attoseconds / 1_000_000_000)

                // Inter-element gap (1 dot within character)
                if ei < code.count - 1 {
                    if dotDuration > pttOffNs {
                        try? await Task.sleep(nanoseconds: dotDuration - pttOffNs)
                    }
                }
            }

            // Inter-character gap: 3 dots (subtract pttOff latency of last element)
            if !shouldStop && ci < chars.count - 1 && chars[ci + 1] != " " {
                try? await Task.sleep(nanoseconds: 3 * dotDuration)
            }
        }

        isKeying = false
    }

    /// Stop keying immediately
    func stop() {
        shouldStop = true
    }

    var isBusy: Bool { isKeying }
}
