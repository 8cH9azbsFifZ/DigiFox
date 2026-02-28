import Foundation

/// FT8 structured message packing and unpacking.
///
/// FT8 77-bit payload layout by message type:
/// - Type 1 (CQ):       i3=0, n3=0  CQ + callsign(28) + grid(15)
/// - Type 1 (Standard): i3=1        call1(28) + call2(28) + R1(1) + grid(15) + i3(3) = 75+3-1
/// - Type 2 (w/report): i3=1        call1(28) + call2(28) + R1(1) + report(15) + i3(3)
/// - Type 4 (Free text):i3=0, n3=0  71 bits free text (13 chars base-43) + padding

// MARK: - Types

enum FT8MessageType: CaseIterable {
    case cq
    case response
    case confirm
    case freeText
}

struct FT8Message {
    var type: FT8MessageType
    var from: String? = nil         // originating callsign
    var to: String? = nil           // destination callsign (or "CQ")
    var grid: String? = nil         // 4-char Maidenhead locator
    var report: String? = nil       // signal report e.g. "+05", "-12"
    var freeText: String? = nil     // up to 13 chars (free text mode)

    /// Human-readable display text (like WSJT-X message column)
    var displayText: String {
        switch type {
        case .cq:
            let g = (grid ?? "").isEmpty ? "" : " \(grid!)"
            return "CQ \(from ?? "")\(g)"
        case .response:
            return "\(to ?? "") \(from ?? "") \(report ?? grid ?? "")"
        case .confirm:
            return "\(to ?? "") \(from ?? "") \(report ?? "73")"
        case .freeText:
            return freeText ?? ""
        }
    }
}

// MARK: - Packing / Unpacking

enum FT8MessagePack {

    // MARK: - Public API

    /// Pack an FT8Message into 77 payload bits.
    static func pack(_ msg: FT8Message) -> [UInt8] {
        switch msg.type {
        case .cq:
            return packCQ(msg)
        case .response:
            return packResponse(msg)
        case .confirm:
            return packConfirm(msg)
        case .freeText:
            return packFreeText(msg)
        }
    }

    /// Unpack 77 payload bits into an FT8Message.
    static func unpack(_ bits: [UInt8]) -> FT8Message {
        guard bits.count >= FT8Protocol.payloadBits else {
            return FT8Message(type: .freeText, freeText: "?")
        }

        let i3 = extractBits(bits, start: 74, count: 3)
        let n3 = extractBits(bits, start: 71, count: 3)

        if i3 == 0 && n3 == 0 {
            // Could be CQ (Type 1 / i3=0,n3=0) or free text
            let c28_1 = extractBits(bits, start: 0, count: 28)
            if c28_1 >= FT8Protocol.cqToken - 3 {
                return unpackCQ(bits)
            }
            return unpackFreeText(bits)
        }

        if i3 == 1 {
            return unpackStandard(bits)
        }

        // Fallback: try free text
        return unpackFreeText(bits)
    }

    // MARK: - CQ  (Type 1, CQ variant)
    // Layout: CQ-token(28) + callsign(28) + R1(1) + grid(15) + extra(2) + n3(3) = 77
    // We use: cq(28) + call(28) + grid(15) + pad(6) = 77

    private static func packCQ(_ msg: FT8Message) -> [UInt8] {
        var bits = [UInt8]()
        appendBits(&bits, value: UInt64(FT8Protocol.cqToken), count: 28)
        appendBits(&bits, value: UInt64(encodeCallsign(msg.from ?? "")), count: 28)
        appendBits(&bits, value: 0, count: 1)
        appendBits(&bits, value: UInt64(encodeGrid(msg.grid ?? "")), count: 15)
        appendBits(&bits, value: 0, count: 5)
        return Array(bits.prefix(FT8Protocol.payloadBits))
    }

    private static func unpackCQ(_ bits: [UInt8]) -> FT8Message {
        let callVal = UInt32(extractBits(bits, start: 28, count: 28))
        let gridVal = UInt16(extractBits(bits, start: 57, count: 15))
        return FT8Message(
            type: .cq,
            from: decodeCallsign(callVal),
            to: "CQ",
            grid: decodeGrid(gridVal)
        )
    }

    // MARK: - Standard message (i3=1)

    private static func packResponse(_ msg: FT8Message) -> [UInt8] {
        var bits = [UInt8]()
        appendBits(&bits, value: UInt64(encodeCallsign(msg.to ?? "")), count: 28)
        appendBits(&bits, value: UInt64(encodeCallsign(msg.from ?? "")), count: 28)
        appendBits(&bits, value: 0, count: 1)
        appendBits(&bits, value: UInt64(encodeReport(msg.report ?? "+00")), count: 15)
        appendBits(&bits, value: 0, count: 2)
        appendBits(&bits, value: 1, count: 3)
        return Array(bits.prefix(FT8Protocol.payloadBits))
    }

    private static func packConfirm(_ msg: FT8Message) -> [UInt8] {
        var bits = [UInt8]()
        appendBits(&bits, value: UInt64(encodeCallsign(msg.to ?? "")), count: 28)
        appendBits(&bits, value: UInt64(encodeCallsign(msg.from ?? "")), count: 28)
        appendBits(&bits, value: 0, count: 1)
        appendBits(&bits, value: UInt64(encodeRoger(msg.report ?? "73")), count: 15)
        appendBits(&bits, value: 0, count: 2)
        appendBits(&bits, value: 1, count: 3)
        return Array(bits.prefix(FT8Protocol.payloadBits))
    }

    private static func unpackStandard(_ bits: [UInt8]) -> FT8Message {
        let call1Val = UInt32(extractBits(bits, start: 0, count: 28))
        let call2Val = UInt32(extractBits(bits, start: 28, count: 28))
        let r1 = Int(extractBits(bits, start: 56, count: 1))
        let rptVal = UInt16(extractBits(bits, start: 57, count: 15))

        let to = decodeCallsign(call1Val)
        let from = decodeCallsign(call2Val)

        // Determine if this is a report, roger, or grid
        let (reportStr, msgType) = decodeReportField(rptVal, r1: r1)

        return FT8Message(
            type: msgType,
            from: from,
            to: to,
            grid: msgType == .response ? "" : "",
            report: reportStr
        )
    }

    // MARK: - Free text (i3=0, n3=0, non-CQ)
    // 71 bits encode 13 characters in base-43

    private static let freeTextChars = " 0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ+-./?".map { $0 }

    private static func packFreeText(_ msg: FT8Message) -> [UInt8] {
        let text = (msg.freeText ?? "").uppercased()
        var padded = text
        while padded.count < 13 { padded.append(" ") }
        let chars = Array(padded.prefix(13))

        // Encode as base-43 big integer
        var value: UInt128Proxy = .zero
        for ch in chars {
            let idx = freeTextChars.firstIndex(of: ch) ?? 0
            value = value.times(43).plus(UInt64(idx))
        }

        // Extract 71 bits
        var raw = [UInt8]()
        for i in stride(from: 70, through: 0, by: -1) {
            raw.append(value.bit(i))
        }

        var bits = raw
        // Pad to 77 bits: 71 data + n3(3)=0 + i3(3)=0
        while bits.count < FT8Protocol.payloadBits {
            bits.append(0)
        }
        return Array(bits.prefix(FT8Protocol.payloadBits))
    }

    private static func unpackFreeText(_ bits: [UInt8]) -> FT8Message {
        // Read 71 bits as a big integer, decode base-43
        var value: UInt128Proxy = .zero
        for i in 0..<71 {
            value = value.times(2).plus(UInt64(bits[i]))
        }

        var chars = [Character]()
        var rem = value
        for _ in 0..<13 {
            let (q, r) = rem.divmod(43)
            let idx = Int(r.low)
            chars.append(idx < freeTextChars.count ? freeTextChars[idx] : " ")
            rem = q
        }
        chars.reverse()
        let text = String(chars).trimmingCharacters(in: .whitespaces)
        return FT8Message(type: .freeText, freeText: text)
    }

    // MARK: - Callsign Encoding (28 bits)
    //
    // Position-specific character maps:
    //   c0: ' '=0, 'A'-'Z'=1-26, '0'-'9'=27-36   (37 values)
    //   c1: '0'-'9'=0-9, 'A'-'Z'=10-35            (36 values)
    //   c2: '0'-'9'=0-9                            (10 values)
    //   c3-c5: ' '=0, 'A'-'Z'=1-26                (27 values)
    //
    // n28 = ((((c0*36 + c1)*10 + c2)*27 + c3)*27 + c4)*27 + c5

    static func encodeCallsign(_ call: String) -> UInt32 {
        let trimmed = call.uppercased().trimmingCharacters(in: .whitespaces)
        if trimmed == "CQ" { return FT8Protocol.cqToken }

        // Align so that the digit falls at position 2 (0-indexed)
        let aligned = alignCallsign(trimmed)

        let c0 = encodeC0(aligned[0])
        let c1 = encodeC1(aligned[1])
        let c2 = encodeC2(aligned[2])
        let c3 = encodeC345(aligned[3])
        let c4 = encodeC345(aligned[4])
        let c5 = encodeC345(aligned[5])

        let val = ((((UInt32(c0) * 36 + UInt32(c1)) * 10 + UInt32(c2)) * 27
                    + UInt32(c3)) * 27 + UInt32(c4)) * 27 + UInt32(c5)
        return val
    }

    static func decodeCallsign(_ val: UInt32) -> String {
        if val == FT8Protocol.cqToken { return "CQ" }
        if val >= FT8Protocol.cqToken - 3 { return "CQ" }
        if val >= FT8Protocol.ntokens { return "?" }

        var rem = val
        let c5 = rem % 27; rem /= 27
        let c4 = rem % 27; rem /= 27
        let c3 = rem % 27; rem /= 27
        let c2 = rem % 10; rem /= 10
        let c1 = rem % 36; rem /= 36
        let c0 = rem

        let chars: [Character] = [
            decodeC0(c0), decodeC1(c1), decodeC2(c2),
            decodeC345(c3), decodeC345(c4), decodeC345(c5)
        ]
        return String(chars).trimmingCharacters(in: .whitespaces)
    }

    /// Align a callsign so the digit is at position 2.
    private static func alignCallsign(_ call: String) -> [Character] {
        let chars = Array(call)
        // Find the first digit
        var digitPos = -1
        for (i, c) in chars.enumerated() {
            if c.isNumber { digitPos = i; break }
        }
        if digitPos < 0 { digitPos = 0 }

        // Pad left so digit is at position 2
        let leftPad = 2 - digitPos
        var aligned = [Character](repeating: " ", count: max(leftPad, 0)) + chars
        // Pad right to 6 characters
        while aligned.count < 6 { aligned.append(" ") }
        return Array(aligned.prefix(6))
    }

    // Position 0: ' '=0, 'A'-'Z'=1-26, '0'-'9'=27-36
    private static func encodeC0(_ c: Character) -> Int {
        if c == " " { return 0 }
        if let a = c.asciiValue {
            if a >= 0x41 && a <= 0x5A { return Int(a - 0x41) + 1 }
            if a >= 0x30 && a <= 0x39 { return Int(a - 0x30) + 27 }
        }
        return 0
    }
    private static func decodeC0(_ v: UInt32) -> Character {
        if v == 0 { return " " }
        if v <= 26 { return Character(UnicodeScalar(0x41 + v - 1)!) }
        if v <= 36 { return Character(UnicodeScalar(0x30 + v - 27)!) }
        return " "
    }

    // Position 1: '0'-'9'=0-9, 'A'-'Z'=10-35
    private static func encodeC1(_ c: Character) -> Int {
        if let a = c.asciiValue {
            if a >= 0x30 && a <= 0x39 { return Int(a - 0x30) }
            if a >= 0x41 && a <= 0x5A { return Int(a - 0x41) + 10 }
        }
        return 0
    }
    private static func decodeC1(_ v: UInt32) -> Character {
        if v <= 9 { return Character(UnicodeScalar(0x30 + v)!) }
        if v <= 35 { return Character(UnicodeScalar(0x41 + v - 10)!) }
        return "0"
    }

    // Position 2: '0'-'9'=0-9
    private static func encodeC2(_ c: Character) -> Int {
        if let a = c.asciiValue, a >= 0x30 && a <= 0x39 {
            return Int(a - 0x30)
        }
        return 0
    }
    private static func decodeC2(_ v: UInt32) -> Character {
        return Character(UnicodeScalar(0x30 + min(v, 9))!)
    }

    // Positions 3-5: ' '=0, 'A'-'Z'=1-26
    private static func encodeC345(_ c: Character) -> Int {
        if c == " " { return 0 }
        if let a = c.asciiValue, a >= 0x41 && a <= 0x5A {
            return Int(a - 0x41) + 1
        }
        return 0
    }
    private static func decodeC345(_ v: UInt32) -> Character {
        if v == 0 { return " " }
        if v <= 26 { return Character(UnicodeScalar(0x41 + v - 1)!) }
        return " "
    }

    // MARK: - Grid Encoding (15 bits)

    static func encodeGrid(_ grid: String) -> UInt16 {
        let g = grid.uppercased()
        guard g.count >= 4 else { return 0 }
        let chars = Array(g)

        guard let lonIdx = charOrd(chars[0], base: "A"),
              let latIdx = charOrd(chars[1], base: "A"),
              let lonSub = charOrd(chars[2], base: "0"),
              let latSub = charOrd(chars[3], base: "0") else { return 0 }

        let lonFull = lonIdx * 10 + lonSub   // 0-179
        let latFull = latIdx * 10 + latSub   // 0-179

        return UInt16(lonFull * 180 + latFull + 1)
    }

    static func decodeGrid(_ val: UInt16) -> String {
        guard val > 0 else { return "" }
        let v = Int(val) - 1
        let latFull = v % 180
        let lonFull = v / 180

        let lonIdx = lonFull / 10
        let lonSub = lonFull % 10
        let latIdx = latFull / 10
        let latSub = latFull % 10

        guard lonIdx < 18, latIdx < 18, lonSub < 10, latSub < 10 else { return "????" }

        let c0 = Character(UnicodeScalar(Int(("A" as Character).asciiValue!) + lonIdx)!)
        let c1 = Character(UnicodeScalar(Int(("A" as Character).asciiValue!) + latIdx)!)
        let c2 = Character(UnicodeScalar(Int(("0" as Character).asciiValue!) + lonSub)!)
        let c3 = Character(UnicodeScalar(Int(("0" as Character).asciiValue!) + latSub)!)

        return String([c0, c1, c2, c3])
    }

    // MARK: - Report Encoding (15 bits)

    /// Signal report: "-30".."+99" → value + 35, giving 5..134.
    /// Special tokens occupy higher values.
    private static let rptRRR:  UInt16 = 1
    private static let rpt73:   UInt16 = 2
    private static let rptRR73: UInt16 = 3
    private static let rptOffset: Int  = 35

    static func encodeReport(_ rpt: String) -> UInt16 {
        let s = rpt.trimmingCharacters(in: .whitespaces).uppercased()
        if s == "RRR"  { return rptRRR }
        if s == "73"   { return rpt73 }
        if s == "RR73" { return rptRR73 }
        guard let val = Int(s) else { return UInt16(rptOffset) }
        return UInt16(clamping: val + rptOffset)
    }

    static func encodeRoger(_ rpt: String) -> UInt16 {
        let s = rpt.trimmingCharacters(in: .whitespaces).uppercased()
        if s == "RRR"  { return rptRRR }
        if s == "RR73" { return rptRR73 }
        if s == "73"   { return rpt73 }
        return rpt73 // default confirm to 73
    }

    private static func decodeReportField(_ val: UInt16, r1: Int) -> (String, FT8MessageType) {
        switch val {
        case rptRRR:  return ("RRR",  .confirm)
        case rpt73:   return ("73",   .confirm)
        case rptRR73: return ("RR73", .confirm)
        default:
            let report = Int(val) - rptOffset
            let prefix = report >= 0 ? "+" : ""
            let rptStr = (r1 != 0 ? "R" : "") + prefix + "\(report)"
            return (rptStr, .response)
        }
    }

    // MARK: - Character Helpers

    private static func charOrd(_ c: Character, base: Character) -> Int? {
        guard let a = c.asciiValue, let b = base.asciiValue else { return nil }
        let v = Int(a) - Int(b)
        return v >= 0 ? v : nil
    }

    // MARK: - Bit Manipulation

    static func appendBits(_ bits: inout [UInt8], value: UInt64, count: Int) {
        for i in stride(from: count - 1, through: 0, by: -1) {
            bits.append(UInt8((value >> i) & 1))
        }
    }

    static func extractBits(_ bits: [UInt8], start: Int, count: Int) -> UInt64 {
        var val: UInt64 = 0
        for i in 0..<count {
            val = (val << 1) | UInt64(bits[start + i] & 1)
        }
        return val
    }

    // MARK: - Text Parsing (WSJT-X format → FT8Message)

    /// Parse a human-readable FT8 message text into an FT8Message struct.
    /// Examples: "CQ DL1ABC JO31", "DL1ABC DK2AB +05", "DL1ABC DK2AB RRR"
    static func parseText(_ text: String, myCall: String = "", myGrid: String = "") -> FT8Message {
        let parts = text.uppercased().split(separator: " ").map { String($0) }
        guard !parts.isEmpty else {
            return FT8Message(type: .freeText, freeText: text)
        }

        if parts[0] == "CQ" {
            // CQ message: "CQ MYCALL MYGRID"
            let from = parts.count > 1 ? parts[1] : myCall
            let grid = parts.count > 2 ? parts[2] : String(myGrid.prefix(4))
            return FT8Message(type: .cq, from: from, to: "CQ", grid: grid)
        }

        if parts.count >= 3 {
            let to = parts[0]
            let from = parts[1]
            let third = parts[2]

            // Check if third field is a confirmation (RRR, RR73, 73)
            if third == "RRR" || third == "RR73" || third == "73" {
                return FT8Message(type: .confirm, from: from, to: to, report: third)
            }

            // Check if third field is a signal report
            if third.hasPrefix("+") || third.hasPrefix("-") || third.hasPrefix("R+") || third.hasPrefix("R-") {
                return FT8Message(type: .response, from: from, to: to, report: third)
            }

            // Might be a grid locator response
            if third.count == 4 && third.first?.isLetter == true {
                return FT8Message(type: .response, from: from, to: to, grid: third)
            }
        }

        // Fallback: free text
        return FT8Message(type: .freeText, freeText: text)
    }
}

// MARK: - UInt128 Proxy (for base-43 free-text arithmetic)

/// Minimal 128-bit unsigned integer for base-43 free-text encoding.
struct UInt128Proxy {
    var high: UInt64
    var low: UInt64

    static let zero = UInt128Proxy(high: 0, low: 0)

    func times(_ n: UInt64) -> UInt128Proxy {
        let (_, _) = low.multipliedReportingOverflow(by: n)
        _ = high &* n
        // Use full-width multiply for precision
        let fullLo = low.multipliedFullWidth(by: n)
        return UInt128Proxy(high: high &* n &+ fullLo.high, low: fullLo.low)
    }

    func plus(_ n: UInt64) -> UInt128Proxy {
        let (sum, overflow) = low.addingReportingOverflow(n)
        return UInt128Proxy(high: overflow ? high &+ 1 : high, low: sum)
    }

    func divmod(_ d: UInt64) -> (UInt128Proxy, UInt128Proxy) {
        // Simple long division for 128-bit / 64-bit
        if high == 0 {
            return (UInt128Proxy(high: 0, low: low / d),
                    UInt128Proxy(high: 0, low: low % d))
        }
        let hq = high / d
        let hr = high % d
        // Combine remainder with low
        // (hr << 64 + low) / d
        let combined = (hr, low)
        let (q2, r2) = divmod128by64(high: combined.0, low: combined.1, divisor: d)
        return (UInt128Proxy(high: hq, low: q2), UInt128Proxy(high: 0, low: r2))
    }

    func bit(_ pos: Int) -> UInt8 {
        if pos < 64 {
            return UInt8((low >> pos) & 1)
        } else {
            return UInt8((high >> (pos - 64)) & 1)
        }
    }

    private func divmod128by64(high: UInt64, low: UInt64, divisor: UInt64) -> (UInt64, UInt64) {
        // Use the dividend (high:low) / divisor via iterative subtraction for correctness
        if high == 0 {
            return (low / divisor, low % divisor)
        }
        // Schoolbook division: process bit by bit
        var remainder: UInt64 = 0
        var quotient: UInt64 = 0
        // Process high bits
        for i in stride(from: 63, through: 0, by: -1) {
            remainder = (remainder << 1) | ((high >> i) & 1)
            // quotient bits here go above 64 bits, already handled by hq
        }
        // Now remainder holds high % divisor conceptually
        // Process low bits
        for i in stride(from: 63, through: 0, by: -1) {
            remainder = (remainder << 1) | ((low >> i) & 1)
            if remainder >= divisor {
                remainder -= divisor
                quotient |= (1 << i)
            }
        }
        return (quotient, remainder)
    }
}
