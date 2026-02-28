import Foundation

struct Station: Identifiable, Hashable {
    let id: String
    var callsign: String
    var grid: String
    var frequency: Double
    var snr: Int
    var lastHeard: Date

    init(callsign: String, grid: String = "", frequency: Double = 0, snr: Int = 0) {
        self.id = callsign
        self.callsign = callsign
        self.grid = grid
        self.frequency = frequency
        self.snr = snr
        self.lastHeard = Date()
    }
}
