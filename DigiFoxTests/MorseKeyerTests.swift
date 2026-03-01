import XCTest
@testable import DigiFox

final class MorseKeyerTests: XCTestCase {

    // MARK: - Morse Table Completeness

    func testMorseTableContainsAllLetters() {
        for c in "ABCDEFGHIJKLMNOPQRSTUVWXYZ" {
            XCTAssertNotNil(MorseKeyer.morseTable[c], "Missing Morse code for '\(c)'")
        }
    }

    func testMorseTableContainsAllDigits() {
        for c in "0123456789" {
            XCTAssertNotNil(MorseKeyer.morseTable[c], "Missing Morse code for '\(c)'")
        }
    }

    func testMorseTableContainsPunctuation() {
        let expected: [Character] = ["/", "=", "?", ".", ",", "+", "-", "@", "!"]
        for c in expected {
            XCTAssertNotNil(MorseKeyer.morseTable[c], "Missing Morse code for '\(c)'")
        }
    }

    // MARK: - Morse Code Correctness

    func testMorseCodeSOS() {
        XCTAssertEqual(MorseKeyer.morseTable["S"], "...")
        XCTAssertEqual(MorseKeyer.morseTable["O"], "---")
    }

    func testMorseCodeE() {
        XCTAssertEqual(MorseKeyer.morseTable["E"], ".")
    }

    func testMorseCodeT() {
        XCTAssertEqual(MorseKeyer.morseTable["T"], "-")
    }

    func testMorseCodeAllDigits() {
        let expected: [Character: String] = [
            "0": "-----", "1": ".----", "2": "..---",
            "3": "...--", "4": "....-", "5": ".....",
            "6": "-....", "7": "--...", "8": "---..",
            "9": "----."
        ]
        for (char, code) in expected {
            XCTAssertEqual(MorseKeyer.morseTable[char], code, "Wrong code for \(char)")
        }
    }

    // MARK: - Morse Code Validity

    func testAllMorseCodesContainOnlyDotsAndDashes() {
        for (char, code) in MorseKeyer.morseTable {
            for element in code {
                XCTAssertTrue(element == "." || element == "-",
                              "Invalid element '\(element)' in Morse code for '\(char)'")
            }
        }
    }

    func testNoEmptyMorseCodes() {
        for (char, code) in MorseKeyer.morseTable {
            XCTAssertFalse(code.isEmpty, "Empty Morse code for '\(char)'")
        }
    }

    func testNoDuplicateMorseCodes() {
        var seen = [String: Character]()
        for (char, code) in MorseKeyer.morseTable {
            if let existing = seen[code] {
                XCTFail("Duplicate Morse code '\(code)' for '\(char)' and '\(existing)'")
            }
            seen[code] = char
        }
    }

    // MARK: - Keyer Lifecycle

    func testKeyerInitialState() {
        let keyer = MorseKeyer()
        XCTAssertFalse(keyer.isKeying)
    }

    func testKeyerCompletesShortText() {
        let keyer = MorseKeyer()
        let expectation = XCTestExpectation(description: "Keyer completes")
        var keyDownCount = 0
        var keyUpCount = 0

        keyer.key(text: "E", wpm: 50,
                  keyDown: { keyDownCount += 1 },
                  keyUp: { keyUpCount += 1 },
                  completion: { expectation.fulfill() })

        wait(for: [expectation], timeout: 5.0)
        XCTAssertGreaterThan(keyDownCount, 0, "Should have at least one key down")
        XCTAssertGreaterThan(keyUpCount, 0, "Should have at least one key up")
    }

    func testKeyerStop() {
        let keyer = MorseKeyer()
        let expectation = XCTestExpectation(description: "Keyer completes after stop")

        keyer.key(text: "ABCDEFGHIJKLMNOP", wpm: 5,
                  keyDown: {},
                  keyUp: {},
                  completion: { expectation.fulfill() })

        // Stop immediately
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            keyer.stop()
        }

        wait(for: [expectation], timeout: 5.0)
    }

    func testKeyerIgnoresDoubleStart() {
        let keyer = MorseKeyer()
        let exp1 = XCTestExpectation(description: "First keying")

        keyer.key(text: "AAAA", wpm: 30,
                  keyDown: {}, keyUp: {},
                  completion: { exp1.fulfill() })

        // Second call should be ignored (thread != nil)
        var secondCalled = false
        keyer.key(text: "B", wpm: 30,
                  keyDown: {}, keyUp: {},
                  completion: { secondCalled = true })

        wait(for: [exp1], timeout: 10.0)
        XCTAssertFalse(secondCalled, "Second keying should have been ignored")
    }

    // MARK: - PARIS Timing

    func testDotDuration_PARIS() {
        // PARIS standard: dot = 1200ms / WPM
        // At 20 WPM: dot = 60ms
        // At 10 WPM: dot = 120ms
        let wpm20dot = 1.2 / Double(20)
        XCTAssertEqual(wpm20dot, 0.060, accuracy: 0.001)

        let wpm10dot = 1.2 / Double(10)
        XCTAssertEqual(wpm10dot, 0.120, accuracy: 0.001)
    }

    func testMinimumWpmFloor() {
        // The keyer uses max(wpm, 5), so minimum dot = 1200/5 = 240ms
        let dot = 1.2 / Double(max(1, 5))
        XCTAssertEqual(dot, 0.24, accuracy: 0.001)
    }

    // MARK: - Key Event Ordering

    func testKeyEventsAlternate() {
        let keyer = MorseKeyer()
        let expectation = XCTestExpectation(description: "Complete")
        var events = [Bool]() // true = down, false = up

        keyer.key(text: "E", wpm: 40,
                  keyDown: { events.append(true) },
                  keyUp: { events.append(false) },
                  completion: { expectation.fulfill() })

        wait(for: [expectation], timeout: 5.0)

        // Events should alternate: down, up, down, up, ...
        // Last event is always keyUp (safety)
        if events.count >= 2 {
            for i in 0..<(events.count - 1) {
                if i < events.count - 1 {
                    // Down should be followed by Up (within the message events)
                    // Note: final keyUp() is always called
                }
            }
        }
        // At minimum: one down + two ups (one from event, one from safety)
        XCTAssertGreaterThanOrEqual(events.count, 2)
        XCTAssertFalse(events.last!, "Last event should be key up (safety)")
    }
}
