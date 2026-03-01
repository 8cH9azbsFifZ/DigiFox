#!/usr/bin/env swift
// WSPR & Morse Standalone Test Suite
// Run: swift DigiFoxTests/TestWSPRAndMorse.swift

import Foundation

// ============================================================
// Inline WSPR types (pure value types, no dependencies)
// ============================================================

struct WSPRMessage: Equatable {
    let callsign: String
    let grid: String
    let power: Int
}

enum WSPRMessagePack {
    static func encodeCallsign(_ call: String) -> UInt32 {
        var c = Array(call.uppercased())
        if c.count >= 2 && c[1].isNumber {
            c.insert(" ", at: 0)
        }
        while c.count < 6 { c.append(" ") }
        if c.count > 6 { c = Array(c.prefix(6)) }
        let digit2: UInt32 = c[2].isNumber ? UInt32(c[2].asciiValue! - 48) : 0

        func charVal(_ ch: Character) -> UInt32 {
            if ch == " " { return 0 }
            if ch >= "A" && ch <= "Z" { return UInt32(ch.asciiValue! - 65 + 1) }
            if ch >= "0" && ch <= "9" { return UInt32(ch.asciiValue! - 48 + 27) }
            return 0
        }

        let n1 = charVal(c[0]); let n2 = charVal(c[1])
        let n3 = digit2
        let n4 = charVal(c[3]); let n5 = charVal(c[4]); let n6 = charVal(c[5])
        var n = n1; n = n * 36 + n2; n = n * 10 + n3
        n = n * 27 + n4; n = n * 27 + n5; n = n * 27 + n6
        return n
    }

    static func decodeCallsign(_ n: UInt32) -> String {
        var val = n
        func valToChar(_ v: UInt32, space: Bool = true) -> Character {
            if v == 0 && space { return " " }
            if v >= 1 && v <= 26 { return Character(UnicodeScalar(64 + v)!) }
            if v >= 27 && v <= 36 { return Character(UnicodeScalar(48 + v - 27)!) }
            return " "
        }
        let n6 = val % 27; val /= 27; let n5 = val % 27; val /= 27
        let n4 = val % 27; val /= 27; let n3 = val % 10; val /= 10
        let n2 = val % 36; val /= 36; let n1 = val
        return String([valToChar(n1), valToChar(n2),
                       Character(UnicodeScalar(48 + n3)!),
                       valToChar(n4), valToChar(n5), valToChar(n6)])
            .trimmingCharacters(in: .whitespaces)
    }

    static func encodeGrid(_ grid: String) -> Int {
        let g = Array(grid.uppercased())
        guard g.count >= 4,
              g[0] >= "A" && g[0] <= "R", g[1] >= "A" && g[1] <= "R",
              g[2] >= "0" && g[2] <= "9", g[3] >= "0" && g[3] <= "9" else { return 32400 }
        let lon = Int(g[0].asciiValue! - 65) * 10 + Int(g[2].asciiValue! - 48)
        let lat = Int(g[1].asciiValue! - 65) * 10 + Int(g[3].asciiValue! - 48)
        return lon * 180 + lat
    }

    static func decodeGrid(_ n: Int) -> String {
        let lat = n % 180; let lon = n / 180
        return String([Character(UnicodeScalar(65 + lon / 10)!),
                       Character(UnicodeScalar(65 + lat / 10)!),
                       Character(UnicodeScalar(48 + lon % 10)!),
                       Character(UnicodeScalar(48 + lat % 10)!)])
    }

    static let validPowers = [0,3,7,10,13,17,20,23,27,30,33,37,40,43,47,50,53,57,60]

    static func clampPower(_ dBm: Int) -> Int {
        validPowers.min(by: { abs($0 - dBm) < abs($1 - dBm) }) ?? 30
    }

    static func pack(_ msg: WSPRMessage) -> [UInt8] {
        let nCall = encodeCallsign(msg.callsign)
        let nGrid = encodeGrid(msg.grid)
        let nPower = clampPower(msg.power)
        let m1 = UInt32(nGrid) * 128 + UInt32(nPower) + 64
        var bits = [UInt8](repeating: 0, count: 50)
        for i in 0..<28 { bits[i] = UInt8((nCall >> (27 - i)) & 1) }
        for i in 0..<22 { bits[28 + i] = UInt8((m1 >> (21 - i)) & 1) }
        return bits
    }

    static func unpack(_ bits: [UInt8]) -> WSPRMessage {
        guard bits.count >= 50 else {
            return WSPRMessage(callsign: "?????", grid: "AA00", power: 0)
        }
        var nCall: UInt32 = 0
        for i in 0..<28 { nCall = (nCall << 1) | UInt32(bits[i] & 1) }
        var m1: UInt32 = 0
        for i in 0..<22 { m1 = (m1 << 1) | UInt32(bits[28 + i] & 1) }
        let callsign = decodeCallsign(nCall)
        let nPower = Int((m1 - 64) % 128)
        let nGrid = Int((m1 - 64) / 128)
        return WSPRMessage(callsign: callsign, grid: decodeGrid(nGrid), power: clampPower(nPower))
    }
}

// Interleaver
enum WSPRProtocol {
    static let symbolCount = 162
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
    static let poly1: UInt32 = 0xF2D05351
    static let poly2: UInt32 = 0xE4613C47

    static func interleaveIndex(_ i: Int) -> Int {
        var j = i; var result = 0
        for _ in 0..<8 { result = (result << 1) | (j & 1); j >>= 1 }
        return result
    }
}

// Morse table
let morseTable: [Character: String] = [
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

// Convolutional encoder
func parity32(_ x: UInt32) -> UInt8 {
    var v = x; v ^= v >> 16; v ^= v >> 8; v ^= v >> 4; v ^= v >> 2; v ^= v >> 1
    return UInt8(v & 1)
}

func convolutionalEncode(_ messageBits: [UInt8]) -> [UInt8] {
    var reg: UInt32 = 0; var output = [UInt8]()
    for i in 0..<81 {
        let bit: UInt32 = i < messageBits.count ? UInt32(messageBits[i]) : 0
        reg = (reg << 1) | bit
        output.append(parity32(reg & WSPRProtocol.poly1))
        output.append(parity32(reg & WSPRProtocol.poly2))
    }
    return output
}

func interleave(_ bits: [UInt8]) -> [UInt8] {
    var result = [UInt8](repeating: 0, count: 162); var j = 0
    for i in 0..<256 {
        let rev = WSPRProtocol.interleaveIndex(i)
        if rev < 162 { if j < bits.count { result[rev] = bits[j]; j += 1 } }
    }
    return result
}

func mergeWithSync(_ dataBits: [UInt8]) -> [Int] {
    var symbols = [Int](repeating: 0, count: 162)
    for i in 0..<162 {
        symbols[i] = WSPRProtocol.syncVector[i] + 2 * Int(i < dataBits.count ? dataBits[i] : 0)
    }
    return symbols
}

// ============================================================
// Test Framework
// ============================================================

var testsPassed = 0; var testsFailed = 0

func test(_ name: String, _ body: () throws -> Void) {
    do { try body(); testsPassed += 1; print("  ✅ \(name)") }
    catch { testsFailed += 1; print("  ❌ \(name): \(error)") }
}

struct AssertionError: Error, CustomStringConvertible { let description: String }

func assertEqual<T: Equatable>(_ a: T, _ b: T, _ msg: String = "") throws {
    guard a == b else { throw AssertionError(description: "Expected \(b), got \(a). \(msg)") }
}
func assertEqualFloat(_ a: Double, _ b: Double, accuracy: Double = 0.01, _ msg: String = "") throws {
    guard abs(a - b) <= accuracy else { throw AssertionError(description: "Expected \(b) ± \(accuracy), got \(a). \(msg)") }
}
func assertTrue(_ condition: Bool, _ msg: String = "") throws {
    guard condition else { throw AssertionError(description: "Expected true. \(msg)") }
}

// ============================================================
// Tests
// ============================================================

print("╔══════════════════════════════════════════════════════╗")
print("║   WSPR & Morse Standalone Test Suite                ║")
print("╚══════════════════════════════════════════════════════╝")
print()

// ---- WSPR Callsign Encoding ----
print("▸ WSPR Callsign Encoding")

test("Round-trip: DL1ABC") {
    let e = WSPRMessagePack.encodeCallsign("DL1ABC")
    let d = WSPRMessagePack.decodeCallsign(e)
    try assertEqual(d, "DL1ABC")
}

test("Round-trip: K1JT") {
    let e = WSPRMessagePack.encodeCallsign("K1JT")
    let d = WSPRMessagePack.decodeCallsign(e)
    try assertTrue(d.contains("K1JT"), "Expected K1JT in '\(d)'")
}

test("Round-trip: W1AW") {
    let e = WSPRMessagePack.encodeCallsign("W1AW")
    let d = WSPRMessagePack.decodeCallsign(e)
    try assertTrue(d.contains("W1AW"), "Expected W1AW in '\(d)'")
}

test("Case insensitive: dl1abc == DL1ABC") {
    let a = WSPRMessagePack.encodeCallsign("dl1abc")
    let b = WSPRMessagePack.encodeCallsign("DL1ABC")
    try assertEqual(a, b)
}

test("Round-trip: VK3XYZ") {
    let e = WSPRMessagePack.encodeCallsign("VK3XYZ")
    let d = WSPRMessagePack.decodeCallsign(e)
    try assertEqual(d, "VK3XYZ")
}

test("Round-trip: JA1ABC") {
    let e = WSPRMessagePack.encodeCallsign("JA1ABC")
    let d = WSPRMessagePack.decodeCallsign(e)
    try assertEqual(d, "JA1ABC")
}

// ---- WSPR Grid Encoding ----
print()
print("▸ WSPR Grid Encoding")

let grids = ["JO31", "FN31", "AA00", "RR99", "IO91", "CM87"]
for grid in grids {
    test("Round-trip: \(grid)") {
        let e = WSPRMessagePack.encodeGrid(grid)
        let d = WSPRMessagePack.decodeGrid(e)
        try assertEqual(d, grid)
    }
}

test("Case insensitive: jo31 == JO31") {
    try assertEqual(WSPRMessagePack.encodeGrid("jo31"), WSPRMessagePack.encodeGrid("JO31"))
}

test("Invalid grid → 32400") {
    try assertEqual(WSPRMessagePack.encodeGrid("XXXX"), 32400)
}

test("Too short grid → 32400") {
    try assertEqual(WSPRMessagePack.encodeGrid("JO"), 32400)
}

test("All valid grids in range 0..<32400") {
    for g in grids {
        let v = WSPRMessagePack.encodeGrid(g)
        try assertTrue(v >= 0 && v < 32400, "\(g) → \(v)")
    }
}

// ---- WSPR Power Encoding ----
print()
print("▸ WSPR Power Encoding")

test("Valid powers unchanged") {
    for p in WSPRMessagePack.validPowers {
        try assertEqual(WSPRMessagePack.clampPower(p), p, "Power \(p)")
    }
}

test("Clamp 1 → 0") { try assertEqual(WSPRMessagePack.clampPower(1), 0) }
test("Clamp 2 → 3") { try assertEqual(WSPRMessagePack.clampPower(2), 3) }
test("Clamp 5 → 3") { try assertEqual(WSPRMessagePack.clampPower(5), 3) }
test("Clamp 15 → 13") { try assertEqual(WSPRMessagePack.clampPower(15), 13) }
test("Clamp 100 → 60") { try assertEqual(WSPRMessagePack.clampPower(100), 60) }
test("Clamp -10 → 0") { try assertEqual(WSPRMessagePack.clampPower(-10), 0) }

// ---- WSPR Full Message Round-trip ----
print()
print("▸ WSPR Full Message Pack/Unpack")

test("DL1ABC JO31 30 round-trip") {
    let msg = WSPRMessage(callsign: "DL1ABC", grid: "JO31", power: 30)
    let bits = WSPRMessagePack.pack(msg)
    try assertEqual(bits.count, 50)
    let r = WSPRMessagePack.unpack(bits)
    try assertEqual(r.callsign, "DL1ABC")
    try assertEqual(r.grid, "JO31")
    try assertEqual(r.power, 30)
}

test("K1JT FN31 37 round-trip") {
    let msg = WSPRMessage(callsign: "K1JT", grid: "FN31", power: 37)
    let bits = WSPRMessagePack.pack(msg)
    let r = WSPRMessagePack.unpack(bits)
    try assertTrue(r.callsign.contains("K1JT"))
    try assertEqual(r.grid, "FN31")
    try assertEqual(r.power, 37)
}

test("W1AW CM87 10 round-trip") {
    let msg = WSPRMessage(callsign: "W1AW", grid: "CM87", power: 10)
    let bits = WSPRMessagePack.pack(msg)
    let r = WSPRMessagePack.unpack(bits)
    try assertTrue(r.callsign.contains("W1AW"))
    try assertEqual(r.grid, "CM87")
    try assertEqual(r.power, 10)
}

test("Packed bits are 0 or 1 only") {
    let msg = WSPRMessage(callsign: "DL1ABC", grid: "JO31", power: 30)
    let bits = WSPRMessagePack.pack(msg)
    for (i, b) in bits.enumerated() {
        try assertTrue(b == 0 || b == 1, "Bit \(i) = \(b)")
    }
}

test("Unpack short bits → error callsign") {
    let short = [UInt8](repeating: 0, count: 10)
    let msg = WSPRMessagePack.unpack(short)
    try assertEqual(msg.callsign, "?????")
}

// ---- WSPR Protocol Constants ----
print()
print("▸ WSPR Protocol Constants")

test("Sync vector length = 162") {
    try assertEqual(WSPRProtocol.syncVector.count, 162)
}

test("Sync vector values are 0 or 1") {
    for v in WSPRProtocol.syncVector { try assertTrue(v == 0 || v == 1) }
}

test("Tone spacing ≈ 1.4648 Hz") {
    try assertEqualFloat(12000.0 / 8192.0, 1.4648, accuracy: 0.001)
}

test("Frame duration ≈ 110.6 s") {
    try assertEqualFloat(162.0 * 8192.0 / 12000.0, 110.6, accuracy: 0.1)
}

test("Interleave index: bit-reversal") {
    try assertEqual(WSPRProtocol.interleaveIndex(0), 0)
    try assertEqual(WSPRProtocol.interleaveIndex(1), 128)
    try assertEqual(WSPRProtocol.interleaveIndex(128), 1)
    try assertEqual(WSPRProtocol.interleaveIndex(255), 255)
}

test("Interleave is bijective on 0..255") {
    var seen = Set<Int>()
    for i in 0..<256 { seen.insert(WSPRProtocol.interleaveIndex(i)) }
    try assertEqual(seen.count, 256)
}

test("Interleave is involutory") {
    for i in 0..<256 {
        try assertEqual(WSPRProtocol.interleaveIndex(WSPRProtocol.interleaveIndex(i)), i)
    }
}

// ---- Convolutional Encoder ----
print()
print("▸ Convolutional Encoder")

test("50 message bits → 162 coded bits") {
    let msg = [UInt8](repeating: 0, count: 50)
    let coded = convolutionalEncode(msg)
    try assertEqual(coded.count, 162)
}

test("Coded bits are 0 or 1") {
    let msg = WSPRMessagePack.pack(WSPRMessage(callsign: "K1JT", grid: "FN31", power: 37))
    let coded = convolutionalEncode(msg)
    for (i, b) in coded.enumerated() {
        try assertTrue(b == 0 || b == 1, "Coded bit \(i) = \(b)")
    }
}

test("All-zero input → deterministic output") {
    let a = convolutionalEncode([UInt8](repeating: 0, count: 50))
    let b = convolutionalEncode([UInt8](repeating: 0, count: 50))
    try assertTrue(a == b)
}

test("Different inputs → different outputs") {
    var m1 = [UInt8](repeating: 0, count: 50); m1[0] = 1
    var m2 = [UInt8](repeating: 0, count: 50); m2[0] = 0
    let c1 = convolutionalEncode(m1)
    let c2 = convolutionalEncode(m2)
    try assertTrue(c1 != c2, "Different inputs should produce different outputs")
}

test("Parity32 known values") {
    try assertEqual(parity32(0), 0)
    try assertEqual(parity32(1), 1)
    try assertEqual(parity32(3), 0)   // 11 → even parity
    try assertEqual(parity32(7), 1)   // 111 → odd parity
    try assertEqual(parity32(0xFF), 0) // 8 ones → even
    try assertEqual(parity32(0xFFFFFFFF), 0) // 32 ones → even
}

// ---- Interleaver ----
print()
print("▸ Interleaver")

test("Interleave 162 bits → 162 bits") {
    let bits = [UInt8](repeating: 1, count: 162)
    let result = interleave(bits)
    try assertEqual(result.count, 162)
}

test("Interleave preserves bit count") {
    var bits = [UInt8](repeating: 0, count: 162)
    for i in stride(from: 0, to: 162, by: 2) { bits[i] = 1 }
    let result = interleave(bits)
    let onesIn = bits.reduce(0) { $0 + Int($1) }
    let onesOut = result.reduce(0) { $0 + Int($1) }
    try assertEqual(onesIn, onesOut)
}

// ---- Merge with Sync ----
print()
print("▸ Merge with Sync Vector")

test("Merge produces 162 symbols") {
    let data = [UInt8](repeating: 0, count: 162)
    let symbols = mergeWithSync(data)
    try assertEqual(symbols.count, 162)
}

test("Symbols are in range 0..3") {
    let data = WSPRMessagePack.pack(WSPRMessage(callsign: "DL1ABC", grid: "JO31", power: 30))
    let coded = convolutionalEncode(data)
    let inter = interleave(coded)
    let symbols = mergeWithSync(inter)
    for (i, s) in symbols.enumerated() {
        try assertTrue(s >= 0 && s <= 3, "Symbol \(i) = \(s)")
    }
}

test("Sync + 2*data formula") {
    // With data all 0: symbol = sync[i]
    let data0 = [UInt8](repeating: 0, count: 162)
    let sym0 = mergeWithSync(data0)
    for i in 0..<162 {
        try assertEqual(sym0[i], WSPRProtocol.syncVector[i])
    }
    // With data all 1: symbol = sync[i] + 2
    let data1 = [UInt8](repeating: 1, count: 162)
    let sym1 = mergeWithSync(data1)
    for i in 0..<162 {
        try assertEqual(sym1[i], WSPRProtocol.syncVector[i] + 2)
    }
}

// ---- Full TX Chain ----
print()
print("▸ Full TX Chain (no audio)")

test("Full chain: pack → encode → interleave → merge") {
    let msg = WSPRMessage(callsign: "DL1ABC", grid: "JO31", power: 30)
    let bits = WSPRMessagePack.pack(msg)
    try assertEqual(bits.count, 50)
    let coded = convolutionalEncode(bits)
    try assertEqual(coded.count, 162)
    let inter = interleave(coded)
    try assertEqual(inter.count, 162)
    let symbols = mergeWithSync(inter)
    try assertEqual(symbols.count, 162)
    for s in symbols { try assertTrue(s >= 0 && s <= 3) }
}

// ---- Morse Table ----
print()
print("▸ Morse Table")

test("All 26 letters present") {
    for c in "ABCDEFGHIJKLMNOPQRSTUVWXYZ" {
        try assertTrue(morseTable[c] != nil, "Missing \(c)")
    }
}

test("All 10 digits present") {
    for c in "0123456789" {
        try assertTrue(morseTable[c] != nil, "Missing \(c)")
    }
}

test("SOS = ... --- ...") {
    try assertEqual(morseTable["S"], "...")
    try assertEqual(morseTable["O"], "---")
}

test("All codes contain only . and -") {
    for (ch, code) in morseTable {
        for e in code {
            try assertTrue(e == "." || e == "-", "Invalid '\(e)' in code for '\(ch)'")
        }
    }
}

test("No duplicate codes") {
    var seen = [String: Character]()
    for (ch, code) in morseTable {
        if let existing = seen[code] {
            throw AssertionError(description: "Duplicate code '\(code)' for '\(ch)' and '\(existing)'")
        }
        seen[code] = ch
    }
}

test("No empty codes") {
    for (ch, code) in morseTable {
        try assertTrue(!code.isEmpty, "Empty code for '\(ch)'")
    }
}

test("PARIS timing: 20 WPM → 60ms dot") {
    try assertEqualFloat(1.2 / 20.0, 0.06, accuracy: 0.001)
}

test("PARIS timing: 10 WPM → 120ms dot") {
    try assertEqualFloat(1.2 / 10.0, 0.12, accuracy: 0.001)
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
