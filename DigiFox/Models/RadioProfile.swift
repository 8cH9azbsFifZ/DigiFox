import Foundation

/// Supported radio connection profiles.
/// Each profile defines how CAT control and audio are routed.
enum RadioProfile: String, CaseIterable, Identifiable {
    case digirig = "Digirig"
    case digirigVOX = "Digirig VOX"
    case trusdx  = "(tr)uSDX"
    case hermes  = "Hermes SDR"

    var id: String { rawValue }

    /// Profiles currently shown in the UI.
    /// Serial-dependent profiles (Digirig, TruSDX) are hidden because iOS lacks USB serial support.
    /// Kept as enum cases so backend code compiles and can be re-enabled later.
    static var visibleCases: [RadioProfile] { [.hermes] }

    /// Hamlib model ID for this profile (0 = user must select)
    var defaultHamlibModel: Int {
        switch self {
        case .digirig: return 0         // User selects rig model
        case .digirigVOX: return 0      // No CAT — audio only, PTT via VOX
        case .trusdx:  return 2028      // Kenwood TS-480 (emulated by TruSDX)
        case .hermes:  return 0         // No Hamlib — uses HPSDR protocol
        }
    }

    /// Default baud rate for CAT serial
    var defaultBaudRate: Int {
        switch self {
        case .digirig: return 38400     // Default for FT-817 (user can change)
        case .digirigVOX: return 0      // No serial port needed
        case .trusdx:  return 115200    // Required for CAT_STREAMING audio
        case .hermes:  return 0         // No serial — network only
        }
    }

    /// Whether audio goes over the serial connection (not USB Audio)
    var usesSerialAudio: Bool {
        switch self {
        case .digirig: return false     // USB Audio Class (Digirig sound card)
        case .digirigVOX: return false  // USB Audio Class (Digirig sound card)
        case .trusdx:  return true      // Audio embedded in serial data stream
        case .hermes:  return false     // Audio over Ethernet (IQ stream)
        }
    }

    /// Whether this profile requires a USB serial port for CAT control
    var requiresSerial: Bool {
        switch self {
        case .digirig: return true
        case .digirigVOX: return false  // Audio only — no serial needed
        case .trusdx: return true
        case .hermes: return false      // Network only — no serial
        }
    }

    /// Whether this profile uses network (Ethernet/WiFi) for communication
    var usesNetwork: Bool {
        switch self {
        case .hermes: return true
        default: return false
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
        case .hermes:
            return "Netzwerk-SDR über Ethernet (HPSDR Protocol 1)"
        }
    }

    /// CAT commands for TX/RX control
    var txCommand: String {
        switch self {
        case .digirig: return ""    // Uses Hamlib PTT
        case .digirigVOX: return "" // No CAT — VOX handles PTT
        case .trusdx:  return "TX0;"
        case .hermes:  return ""    // Uses MOX bit over network
        }
    }

    var rxCommand: String {
        switch self {
        case .digirig: return ""
        case .digirigVOX: return ""
        case .trusdx:  return "RX;"
        case .hermes:  return ""
        }
    }

    /// Tune command (CW mode, for antenna tuning)
    var tuneCommand: String {
        switch self {
        case .digirig: return ""
        case .digirigVOX: return ""
        case .trusdx:  return "TX2;"
        case .hermes:  return ""
        }
    }
}
