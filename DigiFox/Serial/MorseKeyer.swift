import Foundation
import QuartzCore

/// Software Morse keyer for (tr)uSDX.
///
/// The TruSDX does not support the Kenwood KY command for CW text.
/// Instead, CW is keyed by toggling TX0;/RX; with proper timing.
/// Mode must be set to CW (MD3;) first.
///
/// Runs on a dedicated high-priority thread with Thread.sleep for
/// precise real-time timing. Swift async Task.sleep is too imprecise.
///
/// PARIS standard timing:
///   dot  = 1200 / WPM ms
///   dash = 3 × dot
///   inter-element gap = 1 × dot
///   inter-character gap = 3 × dot
///   inter-word gap = 7 × dot
class MorseKeyer {

    private var thread: Thread?
    private var _isKeying = false
    private var _shouldStop = false
    private let lock = NSLock()

    var isKeying: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isKeying
    }

    private var shouldStop: Bool {
        lock.lock(); defer { lock.unlock() }
        return _shouldStop
    }

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

    /// Key a text string as Morse code.
    /// Runs on a dedicated thread for precise timing.
    /// `keyDown` and `keyUp` are called synchronously on the keying thread.
    func key(text: String, wpm: Int, keyDown: @escaping () -> Void, keyUp: @escaping () -> Void, completion: @escaping () -> Void) {
        guard !isKeying else { return }

        lock.lock()
        _isKeying = true
        _shouldStop = false
        lock.unlock()

        let t = Thread {
            self.keyingLoop(text: text, wpm: wpm, keyDown: keyDown, keyUp: keyUp)
            DispatchQueue.main.async {
                self.lock.lock()
                self._isKeying = false
                self.lock.unlock()
                completion()
            }
        }
        t.qualityOfService = .userInteractive
        t.name = "MorseKeyer"
        thread = t
        t.start()
    }

    /// Stop keying immediately
    func stop() {
        lock.lock()
        _shouldStop = true
        lock.unlock()
    }

    private func keyingLoop(text: String, wpm: Int, keyDown: () -> Void, keyUp: () -> Void) {
        // PARIS standard: dot = 1200ms / WPM
        let dotSec = 1.2 / Double(max(wpm, 5))

        let chars = Array(text.uppercased())
        for (ci, char) in chars.enumerated() {
            if shouldStop { break }

            if char == " " {
                // Word gap: 7 dots. Already waited 3 after last char, so 4 more.
                preciseSleep(4.0 * dotSec)
                continue
            }

            guard let code = Self.morseTable[char] else { continue }

            for (ei, element) in code.enumerated() {
                if shouldStop { break }

                let dur = element == "-" ? 3.0 * dotSec : dotSec

                // Key down — measure latency and subtract from sleep
                let t0 = CACurrentMediaTime()
                keyDown()
                let keyDownLatency = CACurrentMediaTime() - t0
                preciseSleep(max(0, dur - keyDownLatency))

                // Key up
                let t1 = CACurrentMediaTime()
                keyUp()
                let keyUpLatency = CACurrentMediaTime() - t1

                // Inter-element gap (1 dot)
                if ei < code.count - 1 {
                    preciseSleep(max(0, dotSec - keyUpLatency))
                }
            }

            // Inter-character gap: 3 dots
            if !shouldStop && ci < chars.count - 1 && chars[ci + 1] != " " {
                preciseSleep(3.0 * dotSec)
            }
        }
    }

    /// High-precision sleep using Thread.sleep + spin-wait for the last 1ms
    private func preciseSleep(_ seconds: Double) {
        guard seconds > 0, !shouldStop else { return }

        let spinThreshold = 0.001
        if seconds > spinThreshold {
            Thread.sleep(forTimeInterval: seconds - spinThreshold)
        }
        let deadline = CACurrentMediaTime() + min(seconds, spinThreshold)
        while CACurrentMediaTime() < deadline && !shouldStop { }
    }
}
