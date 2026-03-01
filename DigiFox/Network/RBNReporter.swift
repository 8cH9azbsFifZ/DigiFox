import Foundation
import CryptoKit

/// RBN Reporter — Submit spots to the Reverse Beacon Network via HTTP POST.
///
/// Ported from wave-owl/src/rbn_reporter.py (Python).
/// Reverse-engineered from the official RBN Aggregator v6.7 (.NET binary).
/// Spots are batched and POSTed to s.php; station identifies via id.php.
///
/// Reference: Reverse Beacon Network — https://www.reversebeacon.net/
/// Origin: wave-owl/src/rbn_reporter.py — class RBNReporter(SpotReporter)
final class RBNReporter: SpotReporting {

    // MARK: - Constants

    private static let aggVersion = "6.7"
    private static let primaryURL = "http://x.reversebeacon.net:88/rx/6"
    private static let backupURL = "http://x.reversebeacon.net:80/rx/6"
    private static let httpTimeout: TimeInterval = 15
    private static let reidentifyInterval: TimeInterval = 600  // 10 min

    private static let bandCodes: [String: String] = [
        "2200m": "1", "630m": "38", "160m": "2", "80m": "3", "60m": "39",
        "40m": "4", "30m": "5", "20m": "6", "17m": "7", "15m": "8",
        "12m": "9", "10m": "10", "6m": "17", "2m": "18", "70cm": "19",
        "23cm": "20",
    ]

    // MARK: - Properties

    private let callsign: String
    private let grid: String
    private let version: String
    private let batchInterval: TimeInterval

    private let fingerprint: String
    private var nodeID: String?
    private var identified = false

    private var spotQueue: [Spot] = []
    private let queueLock = NSLock()
    private var senderThread: Thread?
    private var isRunning = false
    private var usingBackup = false
    private var consecutiveFailures = 0

    // MARK: - Init

    init(callsign: String, grid: String = "", version: String = "DigiFox",
         batchInterval: TimeInterval = 10.0) {
        self.callsign = callsign
        self.grid = grid
        self.version = version
        self.batchInterval = batchInterval
        self.fingerprint = Self.computeFingerprint(callsign)
    }

    // MARK: - SpotReporting

    func start() {
        isRunning = true
        let thread = Thread { [weak self] in self?.senderLoop() }
        thread.name = "rbn-sender"
        thread.qualityOfService = .utility
        thread.start()
        senderThread = thread
        Log.d("RBN", "Started (call=\(callsign), grid=\(grid))")
    }

    func stop() {
        isRunning = false
        senderThread?.cancel()
        senderThread = nil
        Log.d("RBN", "Stopped")
    }

    func report(_ spot: Spot) {
        queueLock.lock()
        spotQueue.append(spot)
        queueLock.unlock()
    }

    // MARK: - Sender Loop

    private func senderLoop() {
        // Initial identification with exponential backoff
        var backoff: TimeInterval = 1.0
        while isRunning && !identified {
            if identify() { break }
            Thread.sleep(forTimeInterval: backoff)
            backoff = min(backoff * 2, 60.0)
        }

        var lastIDTime = Date()
        var lastBatchTime = Date()

        while isRunning {
            // Re-identify every 10 minutes
            if Date().timeIntervalSince(lastIDTime) > Self.reidentifyInterval {
                identify()
                lastIDTime = Date()
            }

            Thread.sleep(forTimeInterval: 0.5)

            let elapsed = Date().timeIntervalSince(lastBatchTime)
            guard elapsed >= batchInterval else { continue }

            queueLock.lock()
            let batch = spotQueue
            spotQueue.removeAll()
            queueLock.unlock()

            if !batch.isEmpty {
                sendBatch(batch)
            }
            lastBatchTime = Date()
        }

        // Flush on shutdown
        queueLock.lock()
        let remaining = spotQueue
        spotQueue.removeAll()
        queueLock.unlock()
        if !remaining.isEmpty { sendBatch(remaining) }
    }

    // MARK: - Identification (id.php)

    @discardableResult
    private func identify() -> Bool {
        let shortHash = Self.computeShortHash(callsign)
        let payload: [String: Any] = [
            "SkimPort": "0",
            "t": "id",
            "aggVersion": Self.aggVersion,
            "skimVersion": version,
            "skimCall": callsign,
            "skimGrid": grid,
            "skimQth": "",
            "skimName": version,
            "skimSignIn": callsign,
            "showIP": "0",
            "shortHash": shortHash,
            "skimValLevel": "0",
            "masterSCPFilter": "0",
            "justCQ": "0",
            "bandLimits": "",
            "cWBandLimits": "",
            "rTTYBandLimits": "",
            "fTBandLimits": "",
            "mIXEDBandLimits": "",
            "fingerPrint": fingerprint,
            "ClockNtp": false,
            "ClockNtpDiff": 0,
        ]

        guard let response = postJSON(endpoint: "id.php", payload: payload) else {
            identified = false
            return false
        }

        if let data = response.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            nodeID = (json["nodeId"] ?? json["aggsNodeId"]).map { "\($0)" }
            Log.d("RBN", "Identified: nodeId=\(nodeID ?? "nil")")
        }
        identified = true
        return true
    }

    // MARK: - Spot Submission (s.php)

    private func sendBatch(_ spots: [Spot]) {
        let spotArrays = spots.map { spotToArray($0) }
        let callsigns = spots.map(\.callsign)
        let payload: [String: Any] = [
            "s": spotArrays,
            "t": "s",
            "e": callsign,
            "h": Self.computeBatchHash(callsigns),
            "tm": Date().timeIntervalSince1970,
            "nTP": false,
            "agg": Self.aggVersion,
            "fp": fingerprint,
        ]
        if postJSON(endpoint: "s.php", payload: payload) != nil {
            Log.d("RBN", "Sent \(spots.count) spots")
        }
    }

    private func spotToArray(_ spot: Spot) -> [String] {
        let freqKHz = String(format: "%.2f", Double(spot.frequency) / 1000.0)
        let snr = String(max(0, spot.snr))
        let bandCode = Self.freqToBandCode(spot.frequency)
        return [freqKHz, spot.callsign, "2", snr, "0", "0", bandCode, spot.mode, "D:"]
    }

    // MARK: - HTTP

    private var activeURL: String {
        usingBackup ? Self.backupURL : Self.primaryURL
    }

    @discardableResult
    private func postJSON(endpoint: String, payload: [String: Any]) -> String? {
        let urlString = "\(activeURL)/\(endpoint)"
        guard let url = URL(string: urlString),
              let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }

        var request = URLRequest(url: url, timeoutInterval: Self.httpTimeout)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Aggregator/\(Self.aggVersion)", forHTTPHeaderField: "User-Agent")

        let sem = DispatchSemaphore(value: 0)
        var result: String?

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            defer { sem.signal() }
            if let error {
                Log.d("RBN", "POST \(endpoint) failed: \(error.localizedDescription)")
                self?.consecutiveFailures += 1
                if (self?.consecutiveFailures ?? 0) >= 3 {
                    self?.usingBackup.toggle()
                    self?.consecutiveFailures = 0
                    Log.d("RBN", "Switched to \(self?.usingBackup == true ? "backup" : "primary") URL")
                }
                return
            }
            self?.consecutiveFailures = 0
            result = data.flatMap { String(data: $0, encoding: .utf8) }
        }.resume()

        sem.wait()
        return result
    }

    // MARK: - Hashing Helpers

    private static func computeFingerprint(_ callsign: String) -> String {
        let parts = [callsign, ProcessInfo.processInfo.hostName, "iOS"].sorted()
        return md5Hex(parts.joined())
    }

    private static func computeShortHash(_ signIn: String) -> String {
        String(md5Hex("hello" + signIn + "world").prefix(8))
    }

    private static func computeBatchHash(_ callsigns: [String]) -> String {
        let camel = callsigns.map { camelCaseCall($0) }.joined()
        return String(md5Hex(camel).prefix(8))
    }

    private static func camelCaseCall(_ call: String) -> String {
        guard call.count >= 2 else { return call }
        return String(call.prefix(1)) + call.dropFirst().lowercased()
    }

    private static func md5Hex(_ input: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Band Mapping

    private static func freqToBandCode(_ freqHz: Int) -> String {
        let mhz = Double(freqHz) / 1e6
        switch mhz {
        case ..<0.3:   return bandCodes["2200m"]!
        case ..<0.6:   return bandCodes["630m"]!
        case ..<2.5:   return bandCodes["160m"]!
        case ..<4.5:   return bandCodes["80m"]!
        case ..<6.0:   return bandCodes["60m"]!
        case ..<8.0:   return bandCodes["40m"]!
        case ..<11.0:  return bandCodes["30m"]!
        case ..<15.0:  return bandCodes["20m"]!
        case ..<19.0:  return bandCodes["17m"]!
        case ..<22.0:  return bandCodes["15m"]!
        case ..<26.0:  return bandCodes["12m"]!
        case ..<40.0:  return bandCodes["10m"]!
        case ..<80.0:  return bandCodes["6m"]!
        case ..<200.0: return bandCodes["2m"]!
        case ..<500.0: return bandCodes["70cm"]!
        default:       return bandCodes["23cm"]!
        }
    }
}
