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

    // Station info (shared across all reporters)
    @AppStorage("txPowerWatts") var txPowerWatts: Int = 5
    @AppStorage("antenna") var antenna: String = ""

    // Spot reporters (all disabled by default)
    @AppStorage("pskReporterEnabled") var pskReporterEnabled = false
    @AppStorage("rbnReporterEnabled") var rbnReporterEnabled = false
    @AppStorage("wsprNetReporterEnabled") var wsprNetReporterEnabled = false

    // Radio profile (Hermes SDR — serial profiles hidden on iOS)
    @AppStorage("radioProfile") var radioProfileRaw: String = RadioProfile.hermes.rawValue

    // Rig control (defaults for Hermes — no serial needed)
    @AppStorage("rigModel") var rigModel: Int = 0
    @AppStorage("rigSerialRate") var rigSerialRate: Int = 0

    var radioProfile: RadioProfile {
        get {
            let profile = RadioProfile(rawValue: radioProfileRaw) ?? .hermes
            // Migrate away from hidden serial profiles
            if !RadioProfile.visibleCases.contains(profile) {
                return .hermes
            }
            return profile
        }
        set {
            radioProfileRaw = newValue.rawValue
            // Auto-configure for selected profile
            // Digirig defaults to FT-817 (1020), TruSDX to TS-480 (2028)
            rigModel = newValue.defaultHamlibModel != 0 ? newValue.defaultHamlibModel : 1020
            rigSerialRate = newValue.defaultBaudRate
        }
    }

    // JS8-specific
    @AppStorage("speedRaw") var speedRaw = 0
    @AppStorage("audioOffset") var audioOffset = 1000.0

    init() {
        // Migrate existing users from hidden serial profiles to Hermes
        if let profile = RadioProfile(rawValue: radioProfileRaw),
           !RadioProfile.visibleCases.contains(profile) {
            radioProfileRaw = RadioProfile.hermes.rawValue
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

    /// Hamlib deaktiviert — funktioniert nicht auf iOS (keine POSIX serial FIFOs).
    var useHamlib: Bool { false }
}
