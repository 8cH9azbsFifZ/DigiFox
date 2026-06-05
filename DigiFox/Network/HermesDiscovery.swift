import Foundation
import Network
import os.log

private let logger = Logger(subsystem: "com.digifox.app", category: "HermesDiscovery")

/// HPSDR Protocol 1 discovery port
let kMetisPort: UInt16 = 1024

/// Result of an HPSDR network discovery
struct HermesDevice: Identifiable, Equatable {
    let id: String  // MAC address
    let ip: String
    let port: UInt16
    let mac: String
    let boardID: UInt8
    let gatewareVersion: UInt8

    var displayName: String {
        "Hermes (Board \(boardID), GW \(gatewareVersion)) @ \(ip)"
    }
}

/// Discovers HPSDR Protocol 1 compatible SDR devices on the local network.
actor HermesDiscovery {
    private var connection: NWConnection?
    private var listener: NWListener?

    /// Send discovery broadcast and collect responses.
    /// Uses Network.framework UDP for iOS compatibility (no jailbreak).
    func discover(timeout: TimeInterval = 2.0) async -> [HermesDevice] {
        // Discovery packet: 0xEFFE02 + 57 zero bytes
        let packet = Data([0xEF, 0xFE, 0x02]) + Data(count: 57)

        return await withCheckedContinuation { continuation in
            let results = ThreadSafeArray<HermesDevice>()
            let seenMACs = ThreadSafeSet<String>()

            let responseQueue = DispatchQueue(label: "hermes.discovery")

            // Use NWListener on port 1024 to receive responses (captures sender IP)
            let listenerParams = NWParameters.udp
            listenerParams.allowLocalEndpointReuse = true
            let listener: NWListener
            do {
                listener = try NWListener(using: listenerParams, on: NWEndpoint.Port(rawValue: kMetisPort)!)
            } catch {
                logger.error("Cannot create listener: \(error)")
                continuation.resume(returning: [])
                return
            }

            listener.newConnectionHandler = { newConn in
                newConn.start(queue: responseQueue)
                newConn.receiveMessage { data, _, _, _ in
                    if let data = data {
                        // Extract sender IP from the incoming connection's endpoint
                        var senderIP = "unknown"
                        if case .hostPort(let host, _) = newConn.currentPath?.remoteEndpoint {
                            senderIP = "\(host)"
                            if senderIP.hasPrefix("::ffff:") { senderIP = String(senderIP.dropFirst(7)) }
                        }
                        if let device = Self.parseResponse(data: data, senderIP: senderIP) {
                            if !seenMACs.contains(device.mac) {
                                seenMACs.insert(device.mac)
                                results.append(device)
                                logger.info("Found: \(device.displayName)")
                            }
                        }
                    }
                    newConn.cancel()
                }
            }
            listener.start(queue: responseQueue)

            // Send broadcast via NWConnection to port 1024
            let broadcastEndpoint = NWEndpoint.hostPort(host: "255.255.255.255", port: NWEndpoint.Port(rawValue: kMetisPort)!)
            let sendParams = NWParameters.udp
            sendParams.allowLocalEndpointReuse = true
            let sendConn = NWConnection(to: broadcastEndpoint, using: sendParams)

            sendConn.start(queue: responseQueue)
            sendConn.stateUpdateHandler = { state in
                if case .ready = state {
                    sendConn.send(content: packet, completion: .contentProcessed { error in
                        if let error = error {
                            logger.error("Discovery send failed: \(error.localizedDescription)")
                        } else {
                            logger.info("Discovery broadcast sent")
                        }
                    })
                }
            }

            // Wait for timeout, then collect results
            responseQueue.asyncAfter(deadline: .now() + timeout) {
                sendConn.cancel()
                listener.cancel()
                continuation.resume(returning: results.values)
            }
        }
    }

    /// Discover with fallback: broadcast first, then direct IP if provided
    func discover(directIP: String? = nil, timeout: TimeInterval = 2.0) async -> [HermesDevice] {
        var results = await discover(timeout: timeout)

        // If no broadcast results and direct IP provided, try unicast
        if results.isEmpty, let ip = directIP {
            logger.info("No broadcast response — trying direct IP: \(ip)")
            if let device = await probeDirectIP(ip, timeout: timeout) {
                results.append(device)
            }
        }
        return results
    }

    /// Probe a specific IP address for an HPSDR device
    private func probeDirectIP(_ ip: String, timeout: TimeInterval) async -> HermesDevice? {
        let packet = Data([0xEF, 0xFE, 0x02]) + Data(count: 57)

        return await withCheckedContinuation { continuation in
            let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(ip), port: NWEndpoint.Port(rawValue: kMetisPort)!)
            let conn = NWConnection(to: endpoint, using: .udp)
            let queue = DispatchQueue(label: "hermes.probe")
            var completed = false

            conn.start(queue: queue)
            conn.stateUpdateHandler = { state in
                guard case .ready = state else { return }
                conn.send(content: packet, completion: .contentProcessed { _ in })
                conn.receiveMessage { data, _, _, _ in
                    queue.async {
                        guard !completed else { return }
                        completed = true
                        conn.cancel()
                        if let data = data, let device = Self.parseResponse(data: data, from: endpoint) {
                            continuation.resume(returning: device)
                        } else {
                            continuation.resume(returning: nil)
                        }
                    }
                }
            }

            queue.asyncAfter(deadline: .now() + timeout) {
                guard !completed else { return }
                completed = true
                conn.cancel()
                continuation.resume(returning: nil)
            }
        }
    }

    /// Parse a discovery response packet with sender IP from listener
    private static func parseResponse(data: Data, senderIP: String) -> HermesDevice? {
        guard data.count >= 60 else { return nil }
        guard data[0] == 0xEF, data[1] == 0xFE else { return nil }

        let status = data[2]
        // 0x02 = free, 0x03 = already in use (still valid for our purposes)
        guard status == 0x02 || status == 0x03 else { return nil }

        let mac = (3..<9).map { String(format: "%02X", data[$0]) }.joined(separator: ":")
        let boardID = data[9]
        let gatewareVersion = data[10]

        return HermesDevice(
            id: mac,
            ip: senderIP,
            port: kMetisPort,
            mac: mac,
            boardID: boardID,
            gatewareVersion: gatewareVersion
        )
    }

    /// Parse a discovery response packet with endpoint (for direct IP probe)
    private static func parseResponse(data: Data, from endpoint: NWEndpoint) -> HermesDevice? {
        var ip = "unknown"
        if case .hostPort(let host, _) = endpoint {
            ip = "\(host)"
            if ip.hasPrefix("::ffff:") { ip = String(ip.dropFirst(7)) }
        }
        return parseResponse(data: data, senderIP: ip)
    }
}

// MARK: - Thread-safe helpers for discovery callbacks

private final class ThreadSafeArray<T>: @unchecked Sendable {
    private var array = [T]()
    private let lock = NSLock()

    func append(_ element: T) {
        lock.lock(); defer { lock.unlock() }
        array.append(element)
    }

    var values: [T] {
        lock.lock(); defer { lock.unlock() }
        return array
    }
}

private final class ThreadSafeSet<T: Hashable>: @unchecked Sendable {
    private var set = Set<T>()
    private let lock = NSLock()

    func contains(_ element: T) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return set.contains(element)
    }

    func insert(_ element: T) {
        lock.lock(); defer { lock.unlock() }
        set.insert(element)
    }
}
