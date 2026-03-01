import Foundation

/// CRC-14 used in FT8 message integrity checks.
/// Uses the reference C implementation from kgoba/ft8_lib (MIT license).
/// Polynomial: 0x2757 (x^14 + x^13 + x^10 + x^9 + x^8 + x^6 + x^4 + x^2 + x + 1).
enum FT8CRC {

    static let polynomial: UInt16 = 0x2757
    static let bits: Int = 14

    /// Compute the 14-bit CRC of `payload` (array of 0/1 UInt8 values, 77 bits).
    /// Uses the ft8_lib reference: CRC is computed over 82 bits (77 payload + 5 zeros).
    static func compute(_ payload: [UInt8]) -> UInt16 {
        // Pack bit array into bytes (MSB first) — ft8_lib expects packed format
        var packed = [UInt8](repeating: 0, count: 13) // 82 bits → 11 bytes needed, pad to 13
        for i in 0..<min(payload.count, 77) {
            if payload[i] != 0 {
                packed[i / 8] |= UInt8(0x80 >> (i % 8))
            }
        }
        // Bits 77-81 are zero (already initialized to 0)
        // "The CRC is calculated on the source-encoded message, zero-extended from 77 to 82 bits"
        return ftx_compute_crc(packed, 82)
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

        // Pack 91 bits into bytes (MSB first)
        var a91 = [UInt8](repeating: 0, count: 12) // FTX_LDPC_K_BYTES = 12
        for i in 0..<min(message.count, 91) {
            if message[i] != 0 {
                a91[i / 8] |= UInt8(0x80 >> (i % 8))
            }
        }

        // Extract CRC from bits 77-90 using ft8_lib
        let extracted = ftx_extract_crc(a91)

        // Zero out CRC bits, compute CRC over 82 bits (77 payload + 5 zeros)
        a91[9] &= 0xF8
        a91[10] = 0
        let calculated = ftx_compute_crc(a91, 82)

        return extracted == calculated
    }
}
