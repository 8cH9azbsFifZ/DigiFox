import Foundation
import SwiftUI

class AppSettings: ObservableObject {
    // Station
    @AppStorage("callsign") var callsign = ""
    @AppStorage("grid") var grid = ""

    // Mode selection
    @AppStorage("digitalMode") var digitalModeRaw = 0

    // Frequency
    @AppStorage("dialFrequency") var dialFrequency = 14_074_000.0

    // Audio
    @AppStorage("txPower") var txPower: Double = 0.5

    // Radio profile (Digirig vs TruSDX)
    @AppStorage("radioProfile") var radioProfileRaw: String = RadioProfile.digirig.rawValue

    // Rig control (default: Yaesu FT-817, 38400 baud)
    @AppStorage("rigModel") var rigModel: Int = 1020
    @AppStorage("rigSerialRate") var rigSerialRate: Int = 38400

    var radioProfile: RadioProfile {
        get { RadioProfile(rawValue: radioProfileRaw) ?? .digirig }
        set {
            radioProfileRaw = newValue.rawValue
            // Auto-configure for selected profile
            rigModel = newValue.defaultHamlibModel != 0 ? newValue.defaultHamlibModel : rigModel
            rigSerialRate = newValue.defaultBaudRate
        }
    }

    // JS8-specific
    @AppStorage("speedRaw") var speedRaw = 0
    @AppStorage("audioOffset") var audioOffset = 1000.0
    @AppStorage("networkHost") var networkHost = "localhost"
    @AppStorage("networkPort") var networkPort = 2442
    @AppStorage("useNetworkMode") var useNetworkMode = false

    init() {
        if UserDefaults.standard.object(forKey: "rigModel") as? Int == 0 {
            rigModel = 1020
        }
    }

    var digitalMode: DigitalMode {
        get { DigitalMode(rawValue: digitalModeRaw) ?? .ft8 }
        set { digitalModeRaw = newValue.rawValue }
    }

    var speed: JS8Speed {
        get { JS8Speed(rawValue: speedRaw) ?? .normal }
        set { speedRaw = newValue.rawValue }
    }

    var useHamlib: Bool { rigModel > 0 }
}
