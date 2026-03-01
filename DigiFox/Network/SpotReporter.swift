import Foundation

/// A decoded spot ready for reporting to external networks.
///
/// Ported from wave-owl (Python) CWSpot dataclass.
/// Origin: wave-owl/src/spot.py — SpotReporter ABC + CWSpot dataclass
struct Spot {
    let timestamp: Date
    let frequency: Int          // Hz
    let callsign: String        // spotted station callsign
    let snr: Int                // dB
    let mode: String            // "FT8", "JS8", "CW", "WSPR"
    let spotterCallsign: String // our callsign
}

/// Protocol for spot reporting services.
///
/// Ported from wave-owl/src/spot.py — SpotReporter ABC
/// Origin: wave-owl/src/spot.py
protocol SpotReporting {
    /// Start the reporter (open connections, begin background threads).
    func start()
    /// Stop the reporter (flush pending spots, close connections).
    func stop()
    /// Submit a spot for reporting.
    func report(_ spot: Spot)
}
