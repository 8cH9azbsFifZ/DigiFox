import Foundation

/// WSPRNet Reporter — Upload WSPR spots to wsprnet.org via HTTP POST.
///
/// Ported from wave-owl/src/wsprnet_reporter.py (Python).
/// Based on the WSJT-X reference implementation (wsprnet.cpp).
/// Spots are buffered and flushed with 200ms delay between POSTs.
///
/// Reference: WSPRnet — https://wsprnet.org/
/// Origin: wave-owl/src/wsprnet_reporter.py — class WSPRNetReporter
final class WSPRNetReporter: SpotReporting {

    // MARK: - Constants

    private static let wsprnetURL = "http://wsprnet.org/post/"
    private static let flushDelay: TimeInterval = 0.2   // 200ms between POSTs (WSJT-X behavior)
    private static let httpTimeout: TimeInterval = 15

    // MARK: - Properties

    private let callsign: String
    private let grid: String
    private let version: String

    private var queue: [String] = []
    private let queueLock = NSLock()
    private var flushThread: Thread?
    private var isRunning = false

    // MARK: - Init

    /// - Parameters:
    ///   - callsign: Receiver station callsign.
    ///   - grid: Receiver Maidenhead grid locator (4 or 6 chars).
    ///   - version: Software version string for the 'version' POST field.
    init(callsign: String, grid: String, version: String = "DigiFox-1.0") {
        self.callsign = callsign
        self.grid = grid
        self.version = version
    }

    // MARK: - SpotReporting

    func start() {
        isRunning = true
        let thread = Thread { [weak self] in self?.flushLoop() }
        thread.name = "wsprnet-reporter"
        thread.qualityOfService = .utility
        thread.start()
        flushThread = thread
        Log.d("WSPRNet", "Started (call=\(callsign), grid=\(grid))")
    }

    func stop() {
        isRunning = false
        flushThread?.cancel()
        flushThread = nil
        drainQueue()
        Log.d("WSPRNet", "Stopped")
    }

    /// Report a generic spot — only processes WSPR mode spots.
    func report(_ spot: Spot) {
        // WSPRNet only accepts WSPR spots; ignore others
        guard spot.mode == "WSPR" else { return }
    }

    // MARK: - WSPR-specific Reporting

    /// Report a WSPR decode with full WSPR-specific metadata.
    ///
    /// - Parameters:
    ///   - txCallsign: Transmitting station callsign.
    ///   - txGrid: Transmitting station grid locator.
    ///   - powerDBm: TX power in dBm.
    ///   - snr: Signal-to-noise ratio in dB.
    ///   - dt: Time offset in seconds.
    ///   - drift: Frequency drift in Hz.
    ///   - txFreqHz: TX frequency in Hz.
    ///   - dialFreqHz: Dial frequency in Hz.
    ///   - timestamp: Decode timestamp (HHMM format).
    func reportWSPR(txCallsign: String, txGrid: String, powerDBm: Int,
                    snr: Int, dt: Double, drift: Int, txFreqHz: Int,
                    dialFreqHz: Int, timestamp: String) {
        let dialMHz = Double(dialFreqHz) / 1e6
        let txMHz = Double(txFreqHz) / 1e6
        let now = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyMMdd"
        formatter.timeZone = TimeZone(identifier: "UTC")

        let params: [(String, String)] = [
            ("function", "wspr"),
            ("rcall", callsign),
            ("rgrid", grid),
            ("rqrg", String(format: "%.6f", dialMHz)),
            ("date", formatter.string(from: now)),
            ("time", timestamp),
            ("sig", "\(snr)"),
            ("dt", String(format: "%.1f", dt)),
            ("drift", "\(drift)"),
            ("tqrg", String(format: "%.6f", txMHz)),
            ("tcall", txCallsign),
            ("tgrid", txGrid),
            ("dbm", "\(powerDBm)"),
            ("version", version),
            ("mode", "2"),
        ]
        let body = params.map { "\($0.0)=\(Self.urlEncode($0.1))" }.joined(separator: "&")

        queueLock.lock()
        queue.append(body)
        queueLock.unlock()
    }

    /// Send a heartbeat to keep the receiver visible on wsprnet.org map.
    func sendHeartbeat(dialFreqHz: Int) {
        let dialMHz = Double(dialFreqHz) / 1e6
        let params: [(String, String)] = [
            ("function", "wsprstat"),
            ("rcall", callsign),
            ("rgrid", grid),
            ("rqrg", String(format: "%.6f", dialMHz)),
            ("tpct", "0"),
            ("tqrg", "0.0"),
            ("dbm", "0"),
            ("version", version),
            ("mode", "2"),
        ]
        let body = params.map { "\($0.0)=\(Self.urlEncode($0.1))" }.joined(separator: "&")

        queueLock.lock()
        queue.append(body)
        queueLock.unlock()
    }

    // MARK: - Flush Loop

    private func flushLoop() {
        while isRunning {
            drainQueue()
            Thread.sleep(forTimeInterval: 1.0)
        }
    }

    private func drainQueue() {
        while true {
            queueLock.lock()
            guard !queue.isEmpty else { queueLock.unlock(); return }
            let body = queue.removeFirst()
            queueLock.unlock()

            post(body: body)
            Thread.sleep(forTimeInterval: Self.flushDelay)
        }
    }

    private func post(body: String) {
        guard let url = URL(string: Self.wsprnetURL),
              let data = body.data(using: .utf8) else { return }

        var request = URLRequest(url: url, timeoutInterval: Self.httpTimeout)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("DigiFox/\(version)", forHTTPHeaderField: "User-Agent")

        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, _, error in
            defer { sem.signal() }
            if let error {
                Log.d("WSPRNet", "POST failed: \(error.localizedDescription)")
            }
        }.resume()
        sem.wait()
    }

    // MARK: - URL Encoding

    private static func urlEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
    }
}
