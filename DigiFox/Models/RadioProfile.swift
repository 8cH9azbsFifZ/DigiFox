import Foundation

/// Supported radio connection profiles.
/// Each profile defines how CAT control and audio are routed.
enum RadioProfile: String, CaseIterable, Identifiable {
    case digirig = "Digirig"
    case digirigVOX = "Digirig VOX"
    case trusdx  = "(tr)uSDX"

    var id: String { rawValue }

    /// Hamlib model ID for this profile (0 = user must select)
    var defaultHamlibModel: Int {
        switch self {
        case .digirig: return 0         // User selects rig model
        case .digirigVOX: return 0      // No CAT — audio only, PTT via VOX
        case .trusdx:  return 2028      // Kenwood TS-480 (emulated by TruSDX)
        }
    }

    /// Default baud rate for CAT serial
    var defaultBaudRate: Int {
        switch self {
        case .digirig: return 38400     // Default for FT-817 (user can change)
        case .digirigVOX: return 0      // No serial port needed
        case .trusdx:  return 115200    // Required for CAT_STREAMING audio
        }
    }

    /// Whether audio goes over the serial connection (not USB Audio)
    var usesSerialAudio: Bool {
        switch self {
        case .digirig: return false     // USB Audio Class (Digirig sound card)
        case .digirigVOX: return false  // USB Audio Class (Digirig sound card)
        case .trusdx:  return true      // Audio embedded in serial data stream
        }
    }

    /// Whether this profile requires a USB serial port for CAT control
    var requiresSerial: Bool {
        switch self {
        case .digirig: return true
        case .digirigVOX: return false  // Audio only — no serial needed
        case .trusdx: return true
        }
    }

    /// Description for UI
    var description: String {
        switch self {
        case .digirig:
            return "USB Audio + CAT Serial (braucht iOS-Treiber)"
        case .digirigVOX:
            return "Nur USB Audio — PTT über VOX am Funkgerät"
        case .trusdx:
            return "Single USB-C: CAT + Audio über Serial (115200, 8N1)"
        }
    }

    /// CAT commands for TX/RX control
    var txCommand: String {
        switch self {
        case .digirig: return ""    // Uses Hamlib PTT
        case .digirigVOX: return "" // No CAT — VOX handles PTT
        case .trusdx:  return "TX0;"
        }
    }

    var rxCommand: String {
        switch self {
        case .digirig: return ""
        case .digirigVOX: return ""
        case .trusdx:  return "RX;"
        }
    }

    /// Tune command (CW mode, for antenna tuning)
    var tuneCommand: String {
        switch self {
        case .digirig: return ""
        case .digirigVOX: return ""
        case .trusdx:  return "TX2;"
        }
    }
}
