import Foundation

enum JS8CRC {
    static let polynomial: UInt16 = 0x2757

    static func compute(_ bits: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0
        for bit in bits {
            let feedback = ((crc >> 13) ^ UInt16(bit)) & 1
            crc = (crc << 1) & 0x3FFF
            if feedback == 1 { crc ^= polynomial }
        }
        return crc
    }

    static func append(to bits: [UInt8]) -> [UInt8] {
        let crc = compute(bits)
        var result = bits
        for i in stride(from: 13, through: 0, by: -1) {
            result.append(UInt8((crc >> i) & 1))
        }
        return result
    }

    static func validate(_ bits: [UInt8]) -> Bool {
        guard bits.count >= 14 else { return false }
        let msg = Array(bits.prefix(bits.count - 14))
        var received: UInt16 = 0
        for bit in bits.suffix(14) { received = (received << 1) | UInt16(bit) }
        return compute(msg) == received
    }
}
