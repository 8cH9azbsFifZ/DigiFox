import Foundation

/// CRC-16 CCITT for ARDOP frame integrity checking.
///
/// Uses polynomial 0x1021 (x¹⁶ + x¹² + x⁵ + 1) with initial value 0xFFFF.
/// This is the standard CRC-16 used in the ARDOP protocol for validating
/// frame headers and data integrity.
///
/// Reference: https://github.com/pflarue/ardop
enum ARDOPCRC {

    private static let polynomial: UInt16 = 0x1021
    private static let initialValue: UInt16 = 0xFFFF

    /// Pre-computed CRC-16 CCITT lookup table for fast computation
    private static let table: [UInt16] = {
        var t = [UInt16](repeating: 0, count: 256)
        for i in 0..<256 {
            var crc = UInt16(i) << 8
            for _ in 0..<8 {
                if crc & 0x8000 != 0 {
                    crc = (crc << 1) ^ polynomial
                } else {
                    crc <<= 1
                }
            }
            t[i] = crc
        }
        return t
    }()

    /// Compute CRC-16 CCITT over a byte array.
    static func compute(_ data: [UInt8]) -> UInt16 {
        var crc = initialValue
        for byte in data {
            let index = Int((crc >> 8) ^ UInt16(byte))
            crc = (crc << 8) ^ table[index & 0xFF]
        }
        return crc
    }

    /// Append CRC-16 to data (big-endian byte order).
    static func append(to data: [UInt8]) -> [UInt8] {
        let crc = compute(data)
        return data + [UInt8(crc >> 8), UInt8(crc & 0xFF)]
    }

    /// Validate data with appended CRC-16.
    static func validate(_ dataWithCRC: [UInt8]) -> Bool {
        guard dataWithCRC.count >= 2 else { return false }
        let data = Array(dataWithCRC.dropLast(2))
        let expected = UInt16(dataWithCRC[dataWithCRC.count - 2]) << 8
                     | UInt16(dataWithCRC[dataWithCRC.count - 1])
        return compute(data) == expected
    }
}
