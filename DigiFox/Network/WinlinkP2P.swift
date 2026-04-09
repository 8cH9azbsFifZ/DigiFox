/// Winlink P2P Mode — Direct station-to-station messaging.
///
/// Enables direct message exchange between two stations without an
/// RMS gateway. Both stations must use ARDOP and be on a common frequency.
///
/// P2P workflow:
/// 1. Station A enters LISTEN mode (ready to receive)
/// 2. Station B sends CONNECT to Station A
/// 3. ARDOP ARQ session is established
/// 4. B2F protocol exchanges messages
/// 5. Disconnect
///
/// Reference: https://github.com/la5nta/pat (P2P mode / listen)

import Foundation

// MARK: - P2P Session State

/// P2P connection state
enum P2PState: String, Sendable {
    case idle = "Idle"
    case listening = "Listening"
    case connecting = "Connecting..."
    case exchanging = "Exchanging..."
    case completed = "Completed"
    case failed = "Failed"
}

// MARK: - P2P Transport (wraps ARDOP ARQ as B2FTransport)

/// Adapter: ARDOP ARQ Session → B2FTransport.
///
/// Wraps the ARDOP ARQ session as a B2FTransport interface so
/// the B2F protocol handler can operate directly over it.
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
        Log.d("P2P", "ARDOPB2FTransport created")
        self.modulator = modulator
        self.demodulator = demodulator
    }

    /// Activates the transport and connects callbacks.
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
            throw WinlinkError.connectionFailed("P2P not connected")
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

    /// Data received from the ARQ session (callback).
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

/// Winlink P2P connection manager.
///
/// Coordinates direct message exchange between two stations.
/// Uses ARDOP ARQ for transport and B2F for message exchange.
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

    /// Start listening for incoming P2P connections.
    @MainActor
    func startListening(bandwidth: ARDOPBandwidth = .bw500) async {
        state = .listening
        statusText = "Waiting for incoming connection..."

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
                    self.statusText = "Connected, exchanging messages..."
                }
                await runB2FExchange(session: session)
            }
        }
    }

    /// Stop listening for incoming connections.
    @MainActor
    func stopListening() async {
        await ardopSession?.disconnect()
        state = .idle
        statusText = ""
    }

    // MARK: - Connect Mode

    /// Connect to another station for P2P message exchange.
    @MainActor
    func connect(to callsign: String, bandwidth: ARDOPBandwidth = .bw500) async {
        state = .connecting
        remoteCallsign = callsign
        statusText = "Connecting to \(callsign)..."

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
                    self.statusText = "Connected to \(callsign), exchanging messages..."
                }
                await runB2FExchange(session: session)
            } else {
                await MainActor.run {
                    self.state = .failed
                    self.statusText = "Connection to \(callsign) failed"
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
                self.statusText = "Exchange completed"
            }
        } catch {
            await MainActor.run {
                self.state = .failed
                self.statusText = "Error: \(error.localizedDescription)"
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
