import Foundation

/// Packs and unpacks JS8 messages into 77-bit payloads.
/// Uses base-43 encoding for free text (up to 13 characters).
enum PackMessage {

    // MARK: - Pack (String → Bits)

    static func pack(_ text: String) -> [UInt8] {
        let charset = JS8Protocol.charset
        let base = UInt32(JS8Protocol.charsetSize)
        let upper = text.uppercased()
        let padded = String((upper + String(repeating: " ", count: 13)).prefix(13))

        // Character indices
        var charIndices = [UInt32]()
        for ch in padded {
            if let idx = charset.firstIndex(of: ch) {
                charIndices.append(UInt32(idx))
            } else {
                charIndices.append(0) // space for unknown
            }
        }

        // Horner's method with base-65536 big number
        var bigNum: [UInt32] = [0, 0, 0, 0, 0] // 80 bits
        for ci in charIndices {
            var carry: UInt32 = 0
            for j in 0..<bigNum.count {
                let prod = bigNum[j] &* base &+ carry
                bigNum[j] = prod & 0xFFFF
                carry = prod >> 16
            }
            var addCarry = ci
            for j in 0..<bigNum.count {
                let sum = bigNum[j] &+ addCarry
                bigNum[j] = sum & 0xFFFF
                addCarry = sum >> 16
                if addCarry == 0 { break }
            }
        }

        // Extract 77 bits MSB-first
        var bits = [UInt8](repeating: 0, count: 77)
        for i in 0..<77 {
            let bitPos = 76 - i
            let wordIdx = bitPos / 16
            let bitIdx = bitPos % 16
            bits[i] = UInt8((bigNum[wordIdx] >> bitIdx) & 1)
        }
        return bits
    }

    // MARK: - Unpack (Bits → String)

    static func unpack(_ bits: [UInt8]) -> String {
        guard bits.count >= 77 else { return "" }
        let charset = JS8Protocol.charset
        let base = UInt32(JS8Protocol.charsetSize)

        // Reconstruct big number from bits
        var bigNum: [UInt32] = [0, 0, 0, 0, 0]
        for i in 0..<77 {
            let bitPos = 76 - i
            let wordIdx = bitPos / 16
            let bitIdx = bitPos % 16
            if bits[i] == 1 {
                bigNum[wordIdx] |= (1 << bitIdx)
            }
        }

        // Extract 13 characters by repeated division
        var chars = [Character]()
        for _ in 0..<13 {
            var remainder: UInt32 = 0
            for j in stride(from: bigNum.count - 1, through: 0, by: -1) {
                let cur = (remainder << 16) | bigNum[j]
                bigNum[j] = cur / base
                remainder = cur % base
            }
            let idx = Int(remainder)
            chars.append(idx < charset.count ? charset[idx] : Character(" "))
        }

        return String(chars.reversed()).trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Directed Message Parsing

    /// Parse "FROM TO: COMMAND" format
    static func parseDirected(_ text: String) -> (from: String?, to: String?, command: String?) {
        let parts = text.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return (nil, nil, nil) }
        let header = parts[0].trimmingCharacters(in: .whitespaces)
        let body = parts[1].trimmingCharacters(in: .whitespaces)
        let callsigns = header.split(separator: " ")
        guard callsigns.count >= 2 else { return (nil, nil, nil) }
        return (String(callsigns[0]), String(callsigns[1]), body)
    }
}
