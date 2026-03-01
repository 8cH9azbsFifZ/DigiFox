import Foundation
import QuartzCore

/// Software Morse keyer for (tr)uSDX.
///
/// Uses absolute-time scheduling: every key event is at a fixed
/// offset from the start time. Jitter in one event never affects
/// the next. Runs on a dedicated .userInteractive thread.
///
/// PARIS standard: dot = 1200ms / WPM
class MorseKeyer {

    private var thread: Thread?
    /// Atomic stop flag — no lock needed, just a plain Bool read/written from 2 threads.
    /// Worst case: one extra spin iteration before noticing stop.
    private var stopFlag = UnsafeMutablePointer<Int32>.allocate(capacity: 1)

    var isKeying: Bool { OSAtomicAdd32(0, stopFlag) != -1 && thread != nil }

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

    init() { stopFlag.pointee = 0 }
    deinit { stopFlag.deallocate() }

    /// Pre-compute all timed events, then execute them with absolute timing.
    func key(text: String, wpm: Int, keyDown: @escaping () -> Void, keyUp: @escaping () -> Void, completion: @escaping () -> Void) {
        guard thread == nil else { return }

        // Reset stop flag from any previous state (-1 after stop)
        stopFlag.pointee = 0

        // Pre-compute event schedule: [(relativeTime, isKeyDown)]
        let dot = 1.2 / Double(max(wpm, 5))
        var events = [(Double, Bool)]()
        var t = 0.0

        let chars = Array(text.uppercased())
        for (ci, char) in chars.enumerated() {
            if char == " " {
                t += 7.0 * dot // word gap (full 7; previous char gap already subtracted below)
                // We added 3 dots after last char, so net = 4 extra. But we always add full 7 for simplicity
                // and don't add char gap after last element. Let's be precise:
                // After last char we did NOT add char gap because the space handles it.
                // Actually let's just handle it cleanly:
                continue
            }

            guard let code = Self.morseTable[char] else { continue }

            for (ei, element) in code.enumerated() {
                let dur = element == "-" ? 3.0 * dot : dot
                events.append((t, true))   // key down
                t += dur
                events.append((t, false))  // key up
                if ei < code.count - 1 {
                    t += dot               // inter-element gap
                }
            }

            // Inter-character gap (3 dots) or word gap
            if ci < chars.count - 1 {
                if chars[ci + 1] == " " {
                    // word gap will be added by space handler: total 7 dots from end of last element
                    t += 7.0 * dot
                } else {
                    t += 3.0 * dot
                }
            }
        }

        OSAtomicCompareAndSwap32(0, 1, stopFlag) // set running

        let sf = stopFlag
        let t2 = Thread {
            let start = CACurrentMediaTime()

            for (time, isDown) in events {
                // Check stop
                if OSAtomicAdd32(0, sf) == -1 { break }

                // Wait until absolute deadline
                let deadline = start + time
                let now = CACurrentMediaTime()
                let remaining = deadline - now
                if remaining > 0.002 {
                    Thread.sleep(forTimeInterval: remaining - 0.001)
                }
                // Spin-wait the last bit (no lock, no syscall)
                while CACurrentMediaTime() < deadline {
                    if OSAtomicAdd32(0, sf) == -1 { break }
                }

                if isDown { keyDown() } else { keyUp() }
            }

            // Ensure key is up
            keyUp()

            sf.pointee = 0 // always reset to idle
            DispatchQueue.main.async { [weak self] in
                self?.thread = nil
                completion()
            }
        }
        t2.qualityOfService = .userInteractive
        t2.name = "MorseKeyer"
        thread = t2
        t2.start()
    }

    func stop() {
        OSAtomicCompareAndSwap32Barrier(1, -1, stopFlag) // signal stop
        thread = nil
    }
}
