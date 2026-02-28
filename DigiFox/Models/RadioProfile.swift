import Foundation

/// Supported radio connection profiles.
/// Each profile defines how CAT control and audio are routed.
enum RadioProfile: String, CaseIterable, Identifiable {
    case digirig = "Digirig"
    case trusdx  = "(tr)uSDX"

    var id: String { rawValue }

    /// Hamlib model ID for this profile (0 = user must select)
    var defaultHamlibModel: Int {
        switch self {
        case .digirig: return 0         // User selects rig model
        case .trusdx:  return 2028      // Kenwood TS-480 (emulated by TruSDX)
        }
    }

    /// Default baud rate for CAT serial
    var defaultBaudRate: Int {
        switch self {
        case .digirig: return 9600
        case .trusdx:  return 115200    // Required for CAT_STREAMING audio
        }
    }

    /// Whether audio goes over the serial connection (not USB Audio)
    var usesSerialAudio: Bool {
        switch self {
        case .digirig: return false     // USB Audio Class (Digirig sound card)
        case .trusdx:  return true      // Audio embedded in serial data stream
        }
    }

    /// Description for UI
    var description: String {
        switch self {
        case .digirig:
            return "USB audio interface + separate CAT serial"
        case .trusdx:
            return "Single USB-C: CAT + Audio über Serial (115200, 8N1)"
        }
    }

    /// CAT commands for TX/RX control
    var txCommand: String {
        switch self {
        case .digirig: return ""    // Uses Hamlib PTT
        case .trusdx:  return "TX0;"
        }
    }

    var rxCommand: String {
        switch self {
        case .digirig: return ""
        case .trusdx:  return "RX;"
        }
    }

    /// Tune command (CW mode, for antenna tuning)
    var tuneCommand: String {
        switch self {
        case .digirig: return ""
        case .trusdx:  return "TX2;"
        }
    }
}
