import Foundation

/// WSPR message encoding and decoding.
///
/// A WSPR message consists of:
///   - Callsign (28 bits): up to 6 characters, digit in 3rd position
///   - Grid locator (15 bits): 4-character Maidenhead (e.g. "JO31")
///   - TX power (7 bits): 0–60 dBm
///
/// Total: 50 bits → convolutional encoding → 162 channel symbols
struct WSPRMessage: Equatable {
    let callsign: String
    let grid: String
    let power: Int      // dBm (0-60)

    var displayText: String {
        "\(callsign) \(grid) \(power)"
    }
}

enum WSPRMessagePack {

    // MARK: - Callsign Encoding (28 bits)

    /// Encode callsign to 28-bit integer.
    /// Callsign format: up to 6 chars, 3rd char must be digit.
    /// Characters: space=0, A-Z=1-26, 0-9=27-36
    static func encodeCallsign(_ call: String) -> UInt32 {
        var c = Array(call.uppercased())

        // Pad/align to 6 characters with digit at position 2
        while c.count < 6 { c.insert(" ", at: 0) }
        if c.count > 6 { c = Array(c.prefix(6)) }

        // If 3rd char is not digit, left-pad with space
        if c.count >= 3 && !c[2].isNumber {
            c.insert(" ", at: 0)
            if c.count > 6 { c = Array(c.prefix(6)) }
        }

        func charVal(_ ch: Character) -> UInt32 {
            if ch == " " { return 0 }
            if ch >= "A" && ch <= "Z" { return UInt32(ch.asciiValue! - 65 + 1) }
            if ch >= "0" && ch <= "9" { return UInt32(ch.asciiValue! - 48 + 27) }
            return 0
        }

        let n1 = charVal(c[0])
        let n2 = charVal(c[1])
        let n3 = UInt32(c[2].asciiValue! - 48)  // must be digit 0-9
        let n4 = charVal(c[3])
        let n5 = charVal(c[4])
        let n6 = charVal(c[5])

        // n = n1*36*10*27*27*27 + n2*10*27*27*27 + n3*27*27*27 + n4*27*27 + n5*27 + n6
        var n = n1
        n = n * 36 + n2
        n = n * 10 + n3
        n = n * 27 + n4
        n = n * 27 + n5
        n = n * 27 + n6
        return n
    }

    /// Decode 28-bit integer to callsign
    static func decodeCallsign(_ n: UInt32) -> String {
        var val = n

        func valToChar(_ v: UInt32, space: Bool = true) -> Character {
            if v == 0 && space { return " " }
            if v >= 1 && v <= 26 { return Character(UnicodeScalar(64 + v)!) }
            if v >= 27 && v <= 36 { return Character(UnicodeScalar(48 + v - 27)!) }
            return " "
        }

        let n6 = val % 27; val /= 27
        let n5 = val % 27; val /= 27
        let n4 = val % 27; val /= 27
        let n3 = val % 10; val /= 10
        let n2 = val % 36; val /= 36
        let n1 = val

        var chars: [Character] = [
            valToChar(n1), valToChar(n2),
            Character(UnicodeScalar(48 + n3)!),
            valToChar(n4), valToChar(n5), valToChar(n6)
        ]

        // Trim leading/trailing spaces
        return String(chars).trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Grid Encoding (15 bits)

    /// Encode 4-character Maidenhead grid to 15-bit integer
    static func encodeGrid(_ grid: String) -> Int {
        let g = Array(grid.uppercased())
        guard g.count >= 4,
              g[0] >= "A" && g[0] <= "R",
              g[1] >= "A" && g[1] <= "R",
              g[2] >= "0" && g[2] <= "9",
              g[3] >= "0" && g[3] <= "9" else { return 32400 } // invalid → center

        let lon = Int(g[0].asciiValue! - 65) * 10 + Int(g[2].asciiValue! - 48)
        let lat = Int(g[1].asciiValue! - 65) * 10 + Int(g[3].asciiValue! - 48)
        return lon * 180 + lat
    }

    /// Decode 15-bit integer to 4-character grid
    static func decodeGrid(_ n: Int) -> String {
        let lat = n % 180
        let lon = n / 180
        let c0 = Character(UnicodeScalar(65 + lon / 10)!)
        let c1 = Character(UnicodeScalar(65 + lat / 10)!)
        let c2 = Character(UnicodeScalar(48 + lon % 10)!)
        let c3 = Character(UnicodeScalar(48 + lat % 10)!)
        return String([c0, c1, c2, c3])
    }

    // MARK: - Power Encoding (7 bits)

    /// Valid WSPR power levels (dBm)
    static let validPowers = [0,3,7,10,13,17,20,23,27,30,33,37,40,43,47,50,53,57,60]

    /// Clamp to nearest valid WSPR power level
    static func clampPower(_ dBm: Int) -> Int {
        validPowers.min(by: { abs($0 - dBm) < abs($1 - dBm) }) ?? 30
    }

    // MARK: - Pack / Unpack

    /// Pack a WSPR message into 50 bits
    static func pack(_ msg: WSPRMessage) -> [UInt8] {
        let nCall = encodeCallsign(msg.callsign)
        let nGrid = encodeGrid(msg.grid)
        let nPower = clampPower(msg.power)

        // Combined: call(28) + grid(15) + power(7) = 50 bits
        // Pack grid and power together: M1 = grid * 128 + power + 64
        let m1 = UInt32(nGrid) * 128 + UInt32(nPower) + 64

        // Pack into 50 bits: 28 bits of call + 22 bits of m1
        var bits = [UInt8](repeating: 0, count: 50)

        for i in 0..<28 {
            bits[i] = UInt8((nCall >> (27 - i)) & 1)
        }
        for i in 0..<22 {
            bits[28 + i] = UInt8((m1 >> (21 - i)) & 1)
        }

        return bits
    }

    /// Unpack 50 bits into a WSPR message
    static func unpack(_ bits: [UInt8]) -> WSPRMessage {
        guard bits.count >= 50 else {
            return WSPRMessage(callsign: "?????", grid: "AA00", power: 0)
        }

        var nCall: UInt32 = 0
        for i in 0..<28 {
            nCall = (nCall << 1) | UInt32(bits[i] & 1)
        }

        var m1: UInt32 = 0
        for i in 0..<22 {
            m1 = (m1 << 1) | UInt32(bits[28 + i] & 1)
        }

        let callsign = decodeCallsign(nCall)
        let nPower = Int((m1 - 64) % 128)
        let nGrid = Int((m1 - 64) / 128)
        let grid = decodeGrid(nGrid)

        return WSPRMessage(callsign: callsign, grid: grid, power: clampPower(nPower))
    }

    /// Parse text input into WSPR message
    static func parseText(_ text: String, myCall: String, myGrid: String, power: Int = 30) -> WSPRMessage {
        WSPRMessage(callsign: myCall.uppercased(), grid: String(myGrid.prefix(4)).uppercased(), power: clampPower(power))
    }
}
