/// Winlink P2P Mode — Direkte Station-zu-Station Nachrichten.
///
/// Ermöglicht den direkten Nachrichtenaustausch zwischen zwei Stationen
/// ohne RMS-Gateway. Beide Stationen müssen ARDOP verwenden und sich
/// auf einer gemeinsamen Frequenz befinden.
///
/// P2P-Ablauf:
/// 1. Station A geht auf LISTEN (Empfangsbereit)
/// 2. Station B sendet CONNECT an Station A
/// 3. ARDOP ARQ Session wird aufgebaut
/// 4. B2F-Protokoll tauscht Nachrichten aus
/// 5. Disconnect
///
/// Referenz: https://github.com/la5nta/pat (P2P mode / listen)

import Foundation

// MARK: - P2P Session State

/// Zustand der P2P-Verbindung
enum P2PState: String, Sendable {
    case idle = "Inaktiv"
    case listening = "Empfangsbereit"
    case connecting = "Verbinde..."
    case exchanging = "Austausch..."
    case completed = "Abgeschlossen"
    case failed = "Fehlgeschlagen"
}

// MARK: - P2P Transport (wraps ARDOP ARQ as B2FTransport)

/// Adapter: ARDOP ARQ Session → B2FTransport.
///
/// Wandelt die ARDOP ARQ Session in ein B2FTransport-Interface um,
/// damit der B2F-Protokoll-Handler direkt darüber arbeiten kann.
final class ARDOPB2FTransport: B2FTransport, @unchecked Sendable {

    private let session: ARDOPSession
    private let modulator: ARDOPModulator
    private let demodulator: ARDOPDemodulator

    /// Buffer for line-based reading from ARQ session
    private var lineBuffer = ""
    private var dataBuffer = Data()
    private let bufferLock = NSLock()

    private(set) var isConnected: Bool = false

    init(session: ARDOPSession, modulator: ARDOPModulator, demodulator: ARDOPDemodulator) {
        self.session = session
        self.modulator = modulator
        self.demodulator = demodulator
    }

    /// Aktiviert den Transport und verbindet Callbacks.
    func activate() async {
        await session.listen()

        // Wire up data received callback
        await MainActor.run {
            // Note: In actual implementation, these callbacks would be
            // set via the actor's interface
        }
        isConnected = true
    }

    func sendLine(_ line: String) async throws {
        let data = Data((line + "\r\n").utf8)
        try await sendData(data)
    }

    func receiveLine() async throws -> String {
        // Wait for a complete line in the buffer
        var attempts = 0
        while attempts < 600 { // 60 second timeout (100ms intervals)
            bufferLock.lock()
            if let nlIndex = lineBuffer.firstIndex(of: "\n") {
                var line = String(lineBuffer[lineBuffer.startIndex..<nlIndex])
                lineBuffer = String(lineBuffer[lineBuffer.index(after: nlIndex)...])
                bufferLock.unlock()

                // Strip CR if present
                if line.hasSuffix("\r") {
                    line = String(line.dropLast())
                }
                return line
            }
            bufferLock.unlock()

            try await Task.sleep(nanoseconds: 100_000_000) // 100ms
            attempts += 1
        }
        throw WinlinkError.timeout
    }

    func sendData(_ data: Data) async throws {
        guard isConnected else {
            throw WinlinkError.connectionFailed("P2P nicht verbunden")
        }
        await session.send(data: data)
    }

    func receiveData(count: Int) async throws -> Data {
        var attempts = 0
        while attempts < 600 {
            bufferLock.lock()
            if dataBuffer.count >= count {
                let result = dataBuffer.prefix(count)
                dataBuffer.removeFirst(count)
                bufferLock.unlock()
                return Data(result)
            }
            bufferLock.unlock()

            try await Task.sleep(nanoseconds: 100_000_000)
            attempts += 1
        }
        throw WinlinkError.timeout
    }

    func sendByte(_ byte: UInt8) async throws {
        try await sendData(Data([byte]))
    }

    func receiveByte() async throws -> UInt8 {
        let data = try await receiveData(count: 1)
        return data[0]
    }

    var onProgress: ((B2FSession.Progress) -> Void)?

    /// Daten vom ARQ Session empfangen (Callback).
    func onARQDataReceived(_ data: Data) {
        bufferLock.lock()
        dataBuffer.append(data)
        if let text = String(data: data, encoding: .utf8) {
            lineBuffer += text
        }
        bufferLock.unlock()
    }

    func disconnect() async {
        await session.disconnect()
        isConnected = false
    }
}

// MARK: - P2P Manager

/// Winlink P2P Verbindungs-Manager.
///
/// Koordiniert den direkten Nachrichtenaustausch zwischen zwei Stationen.
/// Verwendet ARDOP ARQ für den Transport und B2F für den Nachrichtenaustausch.
final class WinlinkP2PManager: ObservableObject {

    @Published var state: P2PState = .idle
    @Published var remoteCallsign: String?
    @Published var statusText: String = ""
    @Published var progress: B2FSession.Progress?

    private var ardopSession: ARDOPSession?
    private var b2fSession: B2FSession?
    private var p2pTransport: ARDOPB2FTransport?

    private let account: WinlinkAccount
    private let mailbox: WinlinkMailbox
    private let modulator: ARDOPModulator
    private let demodulator: ARDOPDemodulator

    init(account: WinlinkAccount,
         mailbox: WinlinkMailbox = .shared,
         modulator: ARDOPModulator = ARDOPModulator(),
         demodulator: ARDOPDemodulator = ARDOPDemodulator()) {
        self.account = account
        self.mailbox = mailbox
        self.modulator = modulator
        self.demodulator = demodulator
    }

    // MARK: - Listen Mode

    /// Starte Empfangsbereitschaft für eingehende P2P-Verbindungen.
    @MainActor
    func startListening(bandwidth: ARDOPBandwidth = .bw500) async {
        state = .listening
        statusText = "Warte auf eingehende Verbindung..."

        let session = ARDOPSession(
            callsign: account.callsign,
            bandwidth: bandwidth
        )
        ardopSession = session

        // Set up callbacks
        await session.listen()

        // Monitor for incoming connections
        Task {
            // In production, this would monitor the demodulator for
            // ConReq frames and process them through the ARQ session
            while await session.state == .listening {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }

            if await session.state == .connected {
                await MainActor.run {
                    self.state = .exchanging
                    self.statusText = "Verbunden, tausche Nachrichten aus..."
                }
                await runB2FExchange(session: session)
            }
        }
    }

    /// Stoppe Empfangsbereitschaft.
    @MainActor
    func stopListening() async {
        await ardopSession?.disconnect()
        state = .idle
        statusText = ""
    }

    // MARK: - Connect Mode

    /// Verbinde zu einer anderen Station für P2P-Nachrichtenaustausch.
    @MainActor
    func connect(to callsign: String, bandwidth: ARDOPBandwidth = .bw500) async {
        state = .connecting
        remoteCallsign = callsign
        statusText = "Verbinde zu \(callsign)..."

        let session = ARDOPSession(
            callsign: account.callsign,
            bandwidth: bandwidth
        )
        ardopSession = session

        await session.connect(to: callsign)

        // Wait for connection
        Task {
            var attempts = 0
            while await session.state == .connecting && attempts < 60 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                attempts += 1
            }

            let currentState = await session.state
            if currentState == .connected {
                await MainActor.run {
                    self.state = .exchanging
                    self.statusText = "Verbunden mit \(callsign), tausche Nachrichten aus..."
                }
                await runB2FExchange(session: session)
            } else {
                await MainActor.run {
                    self.state = .failed
                    self.statusText = "Verbindung zu \(callsign) fehlgeschlagen"
                }
            }
        }
    }

    // MARK: - B2F Exchange

    private func runB2FExchange(session: ARDOPSession) async {
        let transport = ARDOPB2FTransport(
            session: session,
            modulator: modulator,
            demodulator: demodulator
        )
        p2pTransport = transport

        let b2f = B2FSession(
            transport: transport,
            account: account,
            mailbox: mailbox
        )
        b2fSession = b2f

        b2f.onProgress = { [weak self] progress in
            Task { @MainActor in
                self?.progress = progress
                self?.statusText = "\(progress.phase): \(progress.detail)"
            }
        }

        do {
            try await b2f.exchange()
            await MainActor.run {
                self.state = .completed
                self.statusText = "Austausch abgeschlossen"
            }
        } catch {
            await MainActor.run {
                self.state = .failed
                self.statusText = "Fehler: \(error.localizedDescription)"
            }
        }

        await transport.disconnect()
    }

    // MARK: - Cleanup

    @MainActor
    func reset() async {
        await ardopSession?.disconnect()
        ardopSession = nil
        b2fSession = nil
        p2pTransport = nil
        state = .idle
        remoteCallsign = nil
        statusText = ""
        progress = nil
    }
}
