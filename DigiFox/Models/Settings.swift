import Foundation
import SwiftUI

class AppSettings: ObservableObject {
    // Station
    @AppStorage("callsign") var callsign = ""
    @AppStorage("grid") var grid = ""

    // Mode selection
    @AppStorage("digitalMode") var digitalModeRaw = 0

    // Frequency & Band
    @AppStorage("dialFrequency") var dialFrequency = 14_074_000.0
    @AppStorage("selectedBand") var selectedBand: String = "20m"

    /// Update dial frequency when band changes, based on current digital mode
    func selectBand(_ bandId: String) {
        selectedBand = bandId
        if let freq = BandPlan.dialFrequency(band: bandId, mode: digitalMode) {
            dialFrequency = freq
        }
    }

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

    init() {
        if UserDefaults.standard.object(forKey: "rigModel") as? Int == 0 {
            rigModel = 1020
        }
    }

    var digitalMode: DigitalMode {
        get { DigitalMode(rawValue: digitalModeRaw) ?? .ft8 }
        set {
            digitalModeRaw = newValue.rawValue
            // Auto-update dial frequency for the new mode
            if let freq = BandPlan.dialFrequency(band: selectedBand, mode: newValue) {
                dialFrequency = freq
            }
        }
    }

    var speed: JS8Speed {
        get { JS8Speed(rawValue: speedRaw) ?? .normal }
        set { speedRaw = newValue.rawValue }
    }

    var useHamlib: Bool { rigModel > 0 }
}
