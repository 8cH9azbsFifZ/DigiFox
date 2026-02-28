import Foundation

/// CRC-14 used in FT8 message integrity checks.
/// Polynomial: 0x2757 (x^14 + x^13 + x^10 + x^9 + x^8 + x^6 + x^4 + x^2 + x + 1).
enum FT8CRC {

    static let polynomial: UInt16 = 0x2757
    static let bits: Int = 14

    /// Compute the 14-bit CRC of `payload` (array of 0/1 UInt8 values).
    static func compute(_ payload: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0
        for bit in payload {
            let msb = (crc >> 13) & 1
            crc = (crc << 1) | UInt16(bit & 1)
            if msb != 0 {
                crc ^= polynomial
            }
        }
        // Flush 14 zero bits
        for _ in 0..<bits {
            let msb = (crc >> 13) & 1
            crc <<= 1
            if msb != 0 {
                crc ^= polynomial
            }
        }
        return crc & 0x3FFF
    }

    /// Append 14 CRC bits to `payload`, returning a 91-bit array.
    static func append(to payload: [UInt8]) -> [UInt8] {
        let crc = compute(payload)
        var result = payload
        for i in stride(from: bits - 1, through: 0, by: -1) {
            result.append(UInt8((crc >> i) & 1))
        }
        return result
    }

    /// Validate that the trailing 14 bits of `message` (91 bits) match the CRC
    /// of the leading 77 payload bits.
    static func validate(_ message: [UInt8]) -> Bool {
        guard message.count >= FT8Protocol.messageBits else { return false }
        let payload = Array(message[0..<FT8Protocol.payloadBits])
        let expected = compute(payload)
        var received: UInt16 = 0
        for i in 0..<bits {
            received = (received << 1) | UInt16(message[FT8Protocol.payloadBits + i] & 1)
        }
        return expected == received
    }
}
