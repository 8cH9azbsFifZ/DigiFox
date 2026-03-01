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
        connection?.cancel()
        connection = nil
        isConnected = false
        receiveBuffer = Data()
    }

    // MARK: - B2FTransport Protocol

    /// Eine Textzeile senden (mit CRLF).
    func sendLine(_ line: String) async throws {
        let data = Data((line + B2FProtocol.crlf).utf8)
        try await sendData(data)
    }

    /// Eine Textzeile empfangen (bis CRLF).
    func receiveLine() async throws -> String {
        while true {
            // Check if we already have a complete line in the buffer
            if let range = receiveBuffer.range(of: Data("\r\n".utf8)) {
                let lineData = receiveBuffer[receiveBuffer.startIndex..<range.lowerBound]
                receiveBuffer.removeSubrange(receiveBuffer.startIndex...range.upperBound.advanced(by: -1))
                return String(data: Data(lineData), encoding: .utf8) ?? ""
            }

            // Also check for just \n
            if let nlIdx = receiveBuffer.firstIndex(of: 0x0A) {
                var endIdx = nlIdx
                if nlIdx > receiveBuffer.startIndex && receiveBuffer[receiveBuffer.index(before: nlIdx)] == 0x0D {
                    endIdx = receiveBuffer.index(before: nlIdx)
                }
                let lineData = receiveBuffer[receiveBuffer.startIndex..<endIdx]
                receiveBuffer.removeSubrange(receiveBuffer.startIndex...nlIdx)
                return String(data: Data(lineData), encoding: .utf8) ?? ""
            }

            // Read more data
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
