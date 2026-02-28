import Foundation

struct RxMessage: Identifiable, Equatable {
    let id = UUID()
    let timestamp: Date
    let frequency: Double
    let snr: Int
    let deltaTime: Double
    let text: String
    let mode: DigitalMode

    // FT8-specific
    var ft8Message: FT8Message?
    var isCQ: Bool = false
    var isMyCall: Bool = false

    // JS8-specific
    var js8Speed: JS8Speed?
    var from: String?
    var to: String?
    var isDirected: Bool { to != nil }

    static func == (lhs: RxMessage, rhs: RxMessage) -> Bool { lhs.id == rhs.id }
}

struct TxMessage {
    var text: String = ""
    var frequency: Double = 1000.0
    var speed: JS8Speed = .normal
}

struct DemodResult {
    let frequency: Double
    let snr: Double
    let deltaTime: Double
    let bits: [UInt8]
    let message: String
}

struct QSOLogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let callsign: String
    let grid: String
    let frequency: Double
    let report: String
    let mode: String
}
