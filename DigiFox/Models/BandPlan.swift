import Foundation

/// ITU Region for band plan differences
enum ITURegion: String, CaseIterable, Identifiable {
    case region1 = "Region 1 (EU/AF)"
    case region2 = "Region 2 (Americas)"
    case region3 = "Region 3 (Asia/Pacific)"
    var id: String { rawValue }
}

/// Amateur radio band definition
struct Band: Identifiable, Hashable {
    let id: String          // e.g. "160m"
    let name: String        // e.g. "160m"
    let lowerHz: Double     // Band start (Hz)
    let upperHz: Double     // Band end (Hz)
    let wavelength: String  // e.g. "160m"

    var centerHz: Double { (lowerHz + upperHz) / 2.0 }
    var bandwidthKHz: Double { (upperHz - lowerHz) / 1000.0 }

    /// Format frequency for display
    static func formatMHz(_ hz: Double) -> String {
        String(format: "%.3f MHz", hz / 1_000_000)
    }
}

/// Digital mode dial frequencies per band
struct DigitalModeFrequency: Identifiable {
    let id: String
    let band: Band
    let ft8Hz: Double?
    let js8Hz: Double?

    var ft8MHz: String? { ft8Hz.map { Band.formatMHz($0) } }
    var js8MHz: String? { js8Hz.map { Band.formatMHz($0) } }
}

/// Central amateur radio band plan with FT8 and JS8Call dial frequencies.
/// Frequencies are the standard USB dial frequencies used worldwide.
struct BandPlan {

    // MARK: - HF Bands

    static let band160m = Band(id: "160m", name: "160m", lowerHz: 1_810_000, upperHz: 2_000_000, wavelength: "160m")
    static let band80m  = Band(id: "80m",  name: "80m",  lowerHz: 3_500_000, upperHz: 3_800_000, wavelength: "80m")
    static let band60m  = Band(id: "60m",  name: "60m",  lowerHz: 5_351_500, upperHz: 5_366_500, wavelength: "60m")
    static let band40m  = Band(id: "40m",  name: "40m",  lowerHz: 7_000_000, upperHz: 7_200_000, wavelength: "40m")
    static let band30m  = Band(id: "30m",  name: "30m",  lowerHz: 10_100_000, upperHz: 10_150_000, wavelength: "30m")
    static let band20m  = Band(id: "20m",  name: "20m",  lowerHz: 14_000_000, upperHz: 14_350_000, wavelength: "20m")
    static let band17m  = Band(id: "17m",  name: "17m",  lowerHz: 18_068_000, upperHz: 18_168_000, wavelength: "17m")
    static let band15m  = Band(id: "15m",  name: "15m",  lowerHz: 21_000_000, upperHz: 21_450_000, wavelength: "15m")
    static let band12m  = Band(id: "12m",  name: "12m",  lowerHz: 24_890_000, upperHz: 24_990_000, wavelength: "12m")
    static let band10m  = Band(id: "10m",  name: "10m",  lowerHz: 28_000_000, upperHz: 29_700_000, wavelength: "10m")

    // MARK: - VHF/UHF Bands

    static let band6m   = Band(id: "6m",   name: "6m",   lowerHz: 50_000_000, upperHz: 54_000_000, wavelength: "6m")
    static let band2m   = Band(id: "2m",   name: "2m",   lowerHz: 144_000_000, upperHz: 148_000_000, wavelength: "2m")
    static let band70cm = Band(id: "70cm", name: "70cm", lowerHz: 430_000_000, upperHz: 440_000_000, wavelength: "70cm")

    /// All bands in frequency order
    static let allBands: [Band] = [
        band160m, band80m, band60m, band40m, band30m,
        band20m, band17m, band15m, band12m, band10m,
        band6m, band2m, band70cm
    ]

    /// HF bands only (for typical QRP/HF rigs like TruSDX)
    static let hfBands: [Band] = [
        band160m, band80m, band60m, band40m, band30m,
        band20m, band17m, band15m, band12m, band10m
    ]

    // MARK: - FT8 Standard Dial Frequencies (USB)

    /// Standard FT8 dial frequencies per band (Hz).
    /// These are the USB dial frequencies — audio tones are ~200-3000 Hz above.
    static let ft8Frequencies: [String: Double] = [
        "160m":   1_840_000,
        "80m":    3_573_000,
        "60m":    5_357_000,
        "40m":    7_074_000,
        "30m":   10_136_000,
        "20m":   14_074_000,
        "17m":   18_100_000,
        "15m":   21_074_000,
        "12m":   24_915_000,
        "10m":   28_074_000,
        "6m":    50_313_000,
        "2m":   144_174_000,
        "70cm": 432_174_000,
    ]

    // MARK: - JS8Call Standard Dial Frequencies (USB)

    /// Standard JS8Call dial frequencies per band (Hz).
    static let js8Frequencies: [String: Double] = [
        "160m":   1_842_000,
        "80m":    3_578_000,
        "60m":    5_357_000,
        "40m":    7_078_000,
        "30m":   10_130_000,
        "20m":   14_078_000,
        "17m":   18_104_000,
        "15m":   21_078_000,
        "12m":   24_922_000,
        "10m":   28_078_000,
        "6m":    50_318_000,
        "2m":   144_178_000,
        "70cm": 432_178_000,
    ]

    // MARK: - CW Standard Frequencies

    /// Standard CW QRP calling frequencies per band (Hz).
    static let cwFrequencies: [String: Double] = [
        "160m":   1_810_000,
        "80m":    3_560_000,
        "60m":    5_354_000,
        "40m":    7_030_000,
        "30m":   10_116_000,
        "20m":   14_060_000,
        "17m":   18_096_000,
        "15m":   21_060_000,
        "12m":   24_906_000,
        "10m":   28_060_000,
        "6m":    50_090_000,
        "2m":   144_050_000,
        "70cm": 432_050_000,
    ]

    // MARK: - Combined Data

    /// All bands with their digital mode frequencies
    static let digitalModeFrequencies: [DigitalModeFrequency] = allBands.map { band in
        DigitalModeFrequency(
            id: band.id,
            band: band,
            ft8Hz: ft8Frequencies[band.id],
            js8Hz: js8Frequencies[band.id]
        )
    }

    /// Get FT8 frequency for a band
    static func ft8Frequency(for bandId: String) -> Double? {
        ft8Frequencies[bandId]
    }

    /// Get JS8Call frequency for a band
    static func js8Frequency(for bandId: String) -> Double? {
        js8Frequencies[bandId]
    }

    /// Get CW frequency for a band
    static func cwFrequency(for bandId: String) -> Double? {
        cwFrequencies[bandId]
    }

    /// Find which band a frequency belongs to
    static func band(for frequencyHz: Double) -> Band? {
        allBands.first { frequencyHz >= $0.lowerHz && frequencyHz <= $0.upperHz }
    }

    /// Get the appropriate dial frequency for a band and mode
    static func dialFrequency(band: String, mode: DigitalMode) -> Double? {
        switch mode {
        case .ft8:  return ft8Frequencies[band]
        case .js8:  return js8Frequencies[band]
        case .cw:   return cwFrequencies[band]
        }
    }

    /// Bands that have frequencies for a given mode
    static func availableBands(for mode: DigitalMode) -> [Band] {
        allBands.filter { band in
            switch mode {
            case .ft8:  return ft8Frequencies[band.id] != nil
            case .js8:  return js8Frequencies[band.id] != nil
            case .cw:   return cwFrequencies[band.id] != nil
            }
        }
    }
}
