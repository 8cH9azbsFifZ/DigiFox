/// Winlink Telnet-Transport — Internet-Fallback über TCP.
///
/// Ermöglicht Winlink-Zugang über das Internet als Alternative zum HF-Zugang.
/// Verbindet sich mit Winlink CMS (Common Message Server) über Telnet.
///
/// Standard CMS-Server:
/// - server.winlink.org:8772 (Telnet)
/// - cms.winlink.org:8772 (Backup)
///
/// Referenz: https://github.com/la5nta/wl2k-go/tree/master/transport/telnet

import Foundation
import Network

// MARK: - Telnet Transport

/// Winlink CMS Telnet-Verbindung.
///
/// Implementiert das B2FTransport-Protokoll über TCP/IP.
/// Wird als Internet-Fallback verwendet wenn kein HF-Zugang möglich ist.
final class WinlinkTelnet: B2FTransport, @unchecked Sendable {

    /// Standard Winlink CMS Server
    static let defaultServers: [(host: String, port: UInt16)] = [
        ("server.winlink.org", 8772),
        ("cms.winlink.org", 8772),
    ]

    private let host: String
    private let port: UInt16
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.digifox.winlink.telnet")

    /// Timeout für Verbindungsaufbau
    let connectTimeout: TimeInterval
    /// Timeout für einzelne Lese-/Schreiboperationen
    let ioTimeout: TimeInterval

    private(set) var isConnected: Bool = false

    // MARK: - Receive buffer for line-based reading
    private var receiveBuffer = Data()

    init(host: String = "server.winlink.org",
         port: UInt16 = 8772,
         connectTimeout: TimeInterval = 30,
         ioTimeout: TimeInterval = 60) {
        self.host = host
        self.port = port
        self.connectTimeout = connectTimeout
        self.ioTimeout = ioTimeout
    }

    // MARK: - Connection

    /// Verbindung zum CMS-Server herstellen.
    func connect() async throws {
        Log.d("Telnet", "Verbinde zu \(host):\(port)...")
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!
        )

        let params = NWParameters.tcp
        params.requiredInterfaceType = .wifi // Allow cellular too if needed

        connection = NWConnection(to: endpoint, using: params)

        return try await withCheckedThrowingContinuation { continuation in
            connection?.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.isConnected = true
                    Log.d("Telnet", "Verbunden mit \(self?.host ?? "?"):\(self?.port ?? 0)")
                    continuation.resume()
                case .failed(let error):
                    self?.isConnected = false
                    continuation.resume(throwing: WinlinkError.connectionFailed(error.localizedDescription))
                case .cancelled:
                    self?.isConnected = false
                    continuation.resume(throwing: WinlinkError.connectionFailed("Verbindung abgebrochen"))
                default:
                    break
                }
            }
            connection?.start(queue: queue)

            // Timeout
            queue.asyncAfter(deadline: .now() + connectTimeout) { [weak self] in
                guard self?.isConnected == false else { return }
                self?.connection?.cancel()
            }
        }
    }

    /// Verbindung trennen.
    func disconnect() {
        Log.d("Telnet", "Disconnect von \(host):\(port)")
        connection?.cancel()
        connection = nil
        isConnected = false
        receiveBuffer = Data()
    }

    // MARK: - B2FTransport Protocol

    /// Eine Textzeile senden (mit CRLF).
    func sendLine(_ line: String) async throws {
        Log.d("Telnet", "TX: \(line)")
        let data = Data((line + "\r").utf8)  // B2F uses CR only, not CRLF
        try await sendData(data)
    }

    /// Eine Textzeile empfangen (bis CR oder LF).
    func receiveLine() async throws -> String {
        while true {
            // Check for CR or LF in buffer
            if let crIdx = receiveBuffer.firstIndex(of: 0x0D) {
                let lineData = receiveBuffer[receiveBuffer.startIndex..<crIdx]
                receiveBuffer.removeSubrange(receiveBuffer.startIndex...crIdx)
                // Also consume following LF if present
                if !receiveBuffer.isEmpty && receiveBuffer[receiveBuffer.startIndex] == 0x0A {
                    receiveBuffer.removeFirst()
                }
                let line = String(data: Data(lineData), encoding: .utf8) ?? ""
                Log.d("Telnet", "RX: \(line)")
                return line
            }
            if let nlIdx = receiveBuffer.firstIndex(of: 0x0A) {
                let lineData = receiveBuffer[receiveBuffer.startIndex..<nlIdx]
                receiveBuffer.removeSubrange(receiveBuffer.startIndex...nlIdx)
                let line = String(data: Data(lineData), encoding: .utf8) ?? ""
                Log.d("Telnet", "RX: \(line)")
                return line
            }

            let chunk = try await readFromNetwork()
            receiveBuffer.append(chunk)
        }
    }

    /// Binärdaten senden.
    func sendData(_ data: Data) async throws {
        guard let connection = connection, isConnected else {
            throw WinlinkError.connectionFailed("Nicht verbunden")
        }

        return try await withCheckedThrowingContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error = error {
                    continuation.resume(throwing: WinlinkError.connectionFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    /// Exakt `count` Bytes empfangen.
    func receiveData(count: Int) async throws -> Data {
        while receiveBuffer.count < count {
            let chunk = try await readFromNetwork()
            receiveBuffer.append(chunk)
        }

        let data = receiveBuffer.prefix(count)
        receiveBuffer.removeFirst(count)
        return Data(data)
    }

    func sendByte(_ byte: UInt8) async throws {
        try await sendData(Data([byte]))
    }

    func receiveByte() async throws -> UInt8 {
        let data = try await receiveData(count: 1)
        return data[0]
    }

    var onProgress: ((B2FSession.Progress) -> Void)?

    // MARK: - Network I/O

    private func readFromNetwork() async throws -> Data {
        guard let connection = connection, isConnected else {
            throw WinlinkError.connectionFailed("Nicht verbunden")
        }

        return try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, error in
                if let error = error {
                    continuation.resume(throwing: WinlinkError.connectionFailed(error.localizedDescription))
                } else if let data = data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: WinlinkError.connectionFailed("Verbindung geschlossen"))
                }
            }
        }
    }
}

// MARK: - Convenience

extension WinlinkTelnet {
    /// Verbindet sich mit dem besten verfügbaren CMS-Server.
    /// Probiert alle Server der Reihe nach durch.
    static func connectToBestServer(timeout: TimeInterval = 15) async throws -> WinlinkTelnet {
        for server in defaultServers {
            let telnet = WinlinkTelnet(host: server.host, port: server.port, connectTimeout: timeout)
            do {
                try await telnet.connect()
                return telnet
            } catch {
                continue
            }
        }
        throw WinlinkError.connectionFailed("Kein CMS-Server erreichbar")
    }
}
