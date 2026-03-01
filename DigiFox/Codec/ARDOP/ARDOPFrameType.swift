import Foundation

/// Modulation type used in ARDOP data frames.
enum ARDOPModulation: String, CaseIterable, Identifiable {
    case fsk4  = "4FSK"
    case psk4  = "4PSK"   // Differential QPSK
    case psk8  = "8PSK"   // Differential 8PSK
    case qam16 = "16QAM"

    var id: String { rawValue }

    /// Bits per symbol for this modulation
    var bitsPerSymbol: Int {
        switch self {
        case .fsk4:  return 2
        case .psk4:  return 2
        case .psk8:  return 3
        case .qam16: return 4
        }
    }
}

/// Bandwidth class for ARDOP frames.
enum ARDOPBandwidth: Int, CaseIterable, Identifiable {
    case bw200  = 200
    case bw500  = 500
    case bw1000 = 1000
    case bw2000 = 2000

    var id: Int { rawValue }

    var carriers: [Double] {
        switch self {
        case .bw200:  return ARDOPProtocol.carriers200Hz
        case .bw500:  return ARDOPProtocol.carriers500Hz
        case .bw1000: return ARDOPProtocol.carriers1000Hz
        case .bw2000: return ARDOPProtocol.carriers2000Hz
        }
    }

    var carrierCount: Int { carriers.count }
    var label: String { "\(rawValue) Hz" }
}

/// ARDOP frame type definitions.
///
/// Each frame type specifies modulation, bandwidth, symbol rate, and FEC parameters.
/// The frame type byte is transmitted in every frame header using 2-carrier 50-baud 4FSK.
///
/// Naming convention: `{Modulation}.{BandwidthHz}.{BaudRate}[S]`
/// where S = short frame (fewer data symbols).
///
/// Reference: https://github.com/pflarue/ardop
enum ARDOPFrameType: UInt8, CaseIterable, Identifiable {

    var id: UInt8 { rawValue }

    // MARK: - 200 Hz Bandwidth (single carrier)

    case fsk4_200_50S     = 0x30
    case fsk4_200_50      = 0x31
    case psk4_200_100S    = 0x40
    case psk4_200_100     = 0x41
    case psk8_200_100     = 0x42
    case qam16_200_100S   = 0x44
    case qam16_200_100    = 0x45

    // MARK: - 500 Hz Bandwidth (2 carriers)

    case fsk4_500_100S    = 0x50
    case fsk4_500_100     = 0x51
    case psk4_500_100     = 0x60
    case psk8_500_100     = 0x62
    case qam16_500_100    = 0x65

    // MARK: - 1000 Hz Bandwidth (4 carriers)

    case psk4_1000_100    = 0x70
    case psk8_1000_100    = 0x72
    case qam16_1000_100   = 0x75

    // MARK: - 2000 Hz Bandwidth (8 carriers)

    case fsk4_2000_600S   = 0x80
    case fsk4_2000_600    = 0x81
    case psk4_2000_100    = 0x90
    case psk8_2000_100    = 0x92
    case qam16_2000_100   = 0x95

    // MARK: - Control Frames

    case conReq200        = 0xE0
    case conReq500        = 0xE1
    case conReq1000       = 0xE2
    case conReq2000       = 0xE3
    case conAck           = 0xE4
    case disc             = 0xE5
    case discAck          = 0xE6
    case idle             = 0xE7
    case ack              = 0xF0
    case nak              = 0xF1
    case breakFrame       = 0xF2

    // MARK: - Properties

    var modulation: ARDOPModulation {
        switch self {
        case .fsk4_200_50S, .fsk4_200_50,
             .fsk4_500_100S, .fsk4_500_100,
             .fsk4_2000_600S, .fsk4_2000_600:
            return .fsk4
        case .psk4_200_100S, .psk4_200_100,
             .psk4_500_100, .psk4_1000_100, .psk4_2000_100:
            return .psk4
        case .psk8_200_100, .psk8_500_100,
             .psk8_1000_100, .psk8_2000_100:
            return .psk8
        case .qam16_200_100S, .qam16_200_100,
             .qam16_500_100, .qam16_1000_100, .qam16_2000_100:
            return .qam16
        default:
            return .fsk4
        }
    }

    var bandwidth: ARDOPBandwidth {
        switch self {
        case .fsk4_200_50S, .fsk4_200_50,
             .psk4_200_100S, .psk4_200_100,
             .psk8_200_100, .qam16_200_100S, .qam16_200_100,
             .conReq200:
            return .bw200
        case .fsk4_500_100S, .fsk4_500_100,
             .psk4_500_100, .psk8_500_100, .qam16_500_100,
             .conReq500:
            return .bw500
        case .psk4_1000_100, .psk8_1000_100, .qam16_1000_100,
             .conReq1000:
            return .bw1000
        default:
            return .bw2000
        }
    }

    var symbolRate: Double {
        switch self {
        case .fsk4_200_50S, .fsk4_200_50:
            return ARDOPProtocol.baud50
        case .fsk4_2000_600S, .fsk4_2000_600:
            return ARDOPProtocol.baud600
        default:
            return ARDOPProtocol.baud100
        }
    }

    var bitsPerSymbol: Int { modulation.bitsPerSymbol }
    var carrierCount: Int { bandwidth.carrierCount }
    var carriers: [Double] { bandwidth.carriers }
    var symbolSamples: Int { Int(ARDOPProtocol.sampleRate / symbolRate) }

    /// Short frames carry fewer data symbols (for faster ARQ turnaround)
    var isShort: Bool {
        switch self {
        case .fsk4_200_50S, .psk4_200_100S, .qam16_200_100S,
             .fsk4_500_100S, .fsk4_2000_600S:
            return true
        default:
            return false
        }
    }

    /// Number of data symbols per carrier
    var dataSymbolsPerCarrier: Int { isShort ? 20 : 40 }

    /// Total data symbols across all carriers
    var totalDataSymbols: Int { dataSymbolsPerCarrier * carrierCount }

    /// Raw data bits before Reed-Solomon encoding
    var rawDataBits: Int { totalDataSymbols * bitsPerSymbol }

    /// Reed-Solomon parity symbols (more parity for higher-order modulations)
    var rsParitySymbols: Int {
        switch modulation {
        case .fsk4:  return 4
        case .psk4:  return 8
        case .psk8:  return 12
        case .qam16: return 16
        }
    }

    /// Net data bytes after RS overhead
    var netDataBytes: Int {
        let totalBytes = rawDataBits / 8
        return max(0, totalBytes - rsParitySymbols)
    }

    /// Whether this is a control frame (no user data)
    var isControl: Bool { rawValue >= 0xE0 }

    /// Whether this is a data frame
    var isData: Bool { !isControl }

    /// Throughput in bits per second
    var throughputBps: Double {
        Double(bitsPerSymbol) * symbolRate * Double(carrierCount)
    }

    /// Human-readable frame type name
    var name: String {
        switch self {
        case .fsk4_200_50S:    return "4FSK.200.50S"
        case .fsk4_200_50:     return "4FSK.200.50"
        case .psk4_200_100S:   return "4PSK.200.100S"
        case .psk4_200_100:    return "4PSK.200.100"
        case .psk8_200_100:    return "8PSK.200.100"
        case .qam16_200_100S:  return "16QAM.200.100S"
        case .qam16_200_100:   return "16QAM.200.100"
        case .fsk4_500_100S:   return "4FSK.500.100S"
        case .fsk4_500_100:    return "4FSK.500.100"
        case .psk4_500_100:    return "4PSK.500.100"
        case .psk8_500_100:    return "8PSK.500.100"
        case .qam16_500_100:   return "16QAM.500.100"
        case .psk4_1000_100:   return "4PSK.1000.100"
        case .psk8_1000_100:   return "8PSK.1000.100"
        case .qam16_1000_100:  return "16QAM.1000.100"
        case .fsk4_2000_600S:  return "4FSK.2000.600S"
        case .fsk4_2000_600:   return "4FSK.2000.600"
        case .psk4_2000_100:   return "4PSK.2000.100"
        case .psk8_2000_100:   return "8PSK.2000.100"
        case .qam16_2000_100:  return "16QAM.2000.100"
        case .conReq200:       return "ConReq200"
        case .conReq500:       return "ConReq500"
        case .conReq1000:      return "ConReq1000"
        case .conReq2000:      return "ConReq2000"
        case .conAck:          return "ConAck"
        case .disc:            return "DISC"
        case .discAck:         return "DISC ACK"
        case .idle:            return "IDLE"
        case .ack:             return "ACK"
        case .nak:             return "NAK"
        case .breakFrame:      return "BREAK"
        }
    }

    /// All data frame types (excluding control frames)
    static var dataFrames: [ARDOPFrameType] {
        allCases.filter { $0.isData }
    }

    /// Data frame types for a given bandwidth
    static func dataFrames(for bandwidth: ARDOPBandwidth) -> [ARDOPFrameType] {
        dataFrames.filter { $0.bandwidth == bandwidth }
    }
}
