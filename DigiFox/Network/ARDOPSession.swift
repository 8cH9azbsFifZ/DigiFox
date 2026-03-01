/// ARDOP ARQ Session Management — Verbindungsschicht über dem Physical Layer.
///
/// Implementiert das ARQ (Automatic Repeat Request) Protokoll für zuverlässige
/// Datenübertragung über ARDOP. Verwaltet Connection Setup, Handshaking,
/// Retransmission und adaptive Modulationswahl basierend auf Kanalqualität.
///
/// Referenz: https://github.com/pflarue/ardop (ARDOP Spezifikation)
/// Referenz: https://github.com/la5nta/wl2k-go/tree/master/transport/ardop

import Foundation

// MARK: - ARQ Session State Machine

/// Zustand der ARDOP ARQ-Sitzung
enum ARDOPSessionState: String, Sendable {
    case disconnected = "Getrennt"
    case listening = "Empfangsbereit"
    case connecting = "Verbinde..."
    case connected = "Verbunden"
    case sendingData = "Sende Daten"
    case receivingData = "Empfange Daten"
    case disconnecting = "Trenne..."
    case failed = "Fehlgeschlagen"
}

/// ARDOP Bandwidth selection — see ARDOPFrameType.swift for the canonical definition

/// ARQ Frame für die Sitzungsverwaltung
struct ARQFrame: Sendable {
    enum FrameKind: Sendable {
        case conReq(callsign: String, targetCallsign: String, bandwidth: ARDOPBandwidth)
        case conAck(callsign: String, bandwidth: ARDOPBandwidth)
        case disc
        case data(payload: Data, sequenceNumber: Int)
        case ack(sequenceNumber: Int)
        case nak(sequenceNumber: Int)
        case idle
        case ping(callsign: String)
        case pingAck(snr: Int, quality: Int)
        case `break`
    }

    let kind: FrameKind
    let timestamp: Date
    let snr: Int?

    init(kind: FrameKind, snr: Int? = nil) {
        self.kind = kind
        self.timestamp = Date()
        self.snr = snr
    }
}

/// Kanalqualitätsmetrik für adaptive Modulation
struct ChannelQuality: Sendable {
    var snr: Double = 0.0
    var frameErrorRate: Double = 0.0
    var throughput: Double = 0.0
    var lastUpdate: Date = Date()

    /// Empfohlener Frame-Typ basierend auf Kanalqualität
    var recommendedFrameType: ARDOPFrameType {
        if snr > 20 { return .qam16_2000_100 }
        if snr > 15 { return .psk8_2000_100 }
        if snr > 10 { return .psk4_1000_100 }
        if snr > 5 { return .psk4_500_100 }
        if snr > 0 { return .fsk4_500_100 }
        return .fsk4_200_50S
    }
}

// MARK: - ARQ Session Actor

/// Thread-sicherer ARDOP ARQ Session Manager.
///
/// Verwaltet den vollständigen Lebenszyklus einer ARDOP-Verbindung:
/// 1. Connection Request/Acknowledge Handshake
/// 2. Adaptive Modulationswahl basierend auf SNR
/// 3. Datenübertragung mit ARQ (ACK/NAK Retransmission)
/// 4. Sauberes Disconnect
actor ARDOPSession {

    // MARK: - Configuration

    /// Eigenes Rufzeichen
    let myCallsign: String
    /// Maximale Bandwidth
    let maxBandwidth: ARDOPBandwidth
    /// Connection timeout in Sekunden
    let connectionTimeout: TimeInterval
    /// Max retransmission attempts
    let maxRetries: Int

    // MARK: - State

    private(set) var state: ARDOPSessionState = .disconnected
    private(set) var remoteCallsign: String?
    private(set) var channelQuality = ChannelQuality()
    private(set) var currentFrameType: ARDOPFrameType = .fsk4_500_100

    /// Outgoing data queue
    private var txQueue = Data()
    /// Received data buffer
    private var rxBuffer = Data()
    /// Current TX sequence number
    private var txSequence: Int = 0
    /// Last acknowledged sequence
    private var lastAckedSequence: Int = -1
    /// Pending (unacknowledged) frames
    private var pendingFrames: [(seq: Int, data: Data, retries: Int)] = []
    /// Retry count for connection
    private var connectRetries: Int = 0

    // MARK: - Callbacks

    /// Wird aufgerufen wenn sich der Zustand ändert
    var onStateChange: ((ARDOPSessionState) -> Void)?
    /// Wird aufgerufen wenn Daten empfangen wurden
    var onDataReceived: ((Data) -> Void)?
    /// Wird aufgerufen wenn ein Frame gesendet werden soll (→ Modulator → Audio)
    var onTransmitFrame: ((Data, ARDOPFrameType) -> Void)?
    /// Wird aufgerufen wenn ein Control-Frame gesendet werden soll
    var onTransmitControl: ((ARDOPFrameType) -> Void)?

    // MARK: - Init

    init(callsign: String,
         bandwidth: ARDOPBandwidth = .bw500,
         timeout: TimeInterval = 120,
         maxRetries: Int = 10) {
        self.myCallsign = callsign
        self.maxBandwidth = bandwidth
        self.connectionTimeout = timeout
        self.maxRetries = maxRetries
    }

    // MARK: - Connection Management

    /// Verbindungsaufbau zu einer Gegenstelle starten.
    func connect(to targetCallsign: String) {
        guard state == .disconnected || state == .listening else { return }
        remoteCallsign = targetCallsign
        connectRetries = 0
        setState(.connecting)
        sendConnectRequest(to: targetCallsign)
    }

    /// In Empfangsbereitschaft gehen (für eingehende Verbindungen).
    func listen() {
        guard state == .disconnected else { return }
        setState(.listening)
    }

    /// Verbindung trennen.
    func disconnect() {
        guard state != .disconnected else { return }
        setState(.disconnecting)
        onTransmitControl?(.disc)
        // Give time for DISC to be sent, then clean up
        cleanupSession()
    }

    // MARK: - Data Transfer

    /// Daten in die Sendewarteschlange stellen.
    func send(data: Data) {
        guard state == .connected else { return }
        txQueue.append(data)
        sendNextDataFrame()
    }

    /// Alle empfangenen Daten abholen und Buffer leeren.
    func receiveAll() -> Data {
        let data = rxBuffer
        rxBuffer = Data()
        return data
    }

    /// Anzahl der Bytes in der Sendewarteschlange.
    var txQueueLength: Int { txQueue.count }

    /// Anzahl der empfangenen Bytes.
    var rxBufferLength: Int { rxBuffer.count }

    // MARK: - Frame Processing (called from Demodulator)

    /// Eingehendes ARQ-Frame verarbeiten.
    func processReceivedFrame(_ frame: ARQFrame) {
        switch frame.kind {
        case .conReq(let callsign, let target, let bandwidth):
            handleConReq(from: callsign, target: target, bandwidth: bandwidth)

        case .conAck(let callsign, let bandwidth):
            handleConAck(from: callsign, bandwidth: bandwidth)

        case .disc:
            handleDisconnect()

        case .data(let payload, let seq):
            handleDataFrame(payload: payload, seq: seq, snr: frame.snr)

        case .ack(let seq):
            handleAck(seq: seq)

        case .nak(let seq):
            handleNak(seq: seq)

        case .idle:
            updateChannelQuality(snr: frame.snr)

        case .ping(let callsign):
            handlePing(from: callsign)

        case .pingAck(let snr, _):
            updateChannelQuality(snr: snr)

        case .break:
            handleBreak()
        }
    }

    // MARK: - Internal Handlers

    private func sendConnectRequest(to target: String) {
        let bwType: ARDOPFrameType
        switch maxBandwidth {
        case .bw200:  bwType = .conReq200
        case .bw500:  bwType = .conReq500
        case .bw1000: bwType = .conReq1000
        case .bw2000: bwType = .conReq2000
        }
        onTransmitControl?(bwType)
    }

    private func handleConReq(from callsign: String, target: String, bandwidth: ARDOPBandwidth) {
        guard state == .listening else { return }
        guard target.uppercased() == myCallsign.uppercased() else { return }

        remoteCallsign = callsign
        setState(.connected)
        onTransmitControl?(.conAck)
    }

    private func handleConAck(from callsign: String, bandwidth: ARDOPBandwidth) {
        guard state == .connecting else { return }
        remoteCallsign = callsign
        txSequence = 0
        lastAckedSequence = -1
        pendingFrames.removeAll()
        setState(.connected)
    }

    private func handleDisconnect() {
        cleanupSession()
    }

    private func handleDataFrame(payload: Data, seq: Int, snr: Int?) {
        guard state == .connected || state == .receivingData else { return }
        setState(.receivingData)

        // Buffer received data
        rxBuffer.append(payload)
        onDataReceived?(payload)

        // Send ACK
        updateChannelQuality(snr: snr)
        onTransmitControl?(.ack)

        // Return to connected after processing
        setState(.connected)
    }

    private func handleAck(seq: Int) {
        guard state == .connected || state == .sendingData else { return }

        // Remove acknowledged frame from pending
        pendingFrames.removeAll { $0.seq <= seq }
        lastAckedSequence = seq

        // Adapt modulation based on success
        adaptModulation(success: true)

        // Send next frame if available
        if !txQueue.isEmpty {
            sendNextDataFrame()
        } else if pendingFrames.isEmpty {
            setState(.connected)
        }
    }

    private func handleNak(seq: Int) {
        guard state == .connected || state == .sendingData else { return }

        // Retransmit the NAK'd frame
        if let idx = pendingFrames.firstIndex(where: { $0.seq == seq }) {
            pendingFrames[idx].retries += 1
            if pendingFrames[idx].retries >= maxRetries {
                setState(.failed)
                return
            }
            // Downgrade modulation on NAK
            adaptModulation(success: false)
            let frameData = pendingFrames[idx].data
            onTransmitFrame?(frameData, currentFrameType)
        }
    }

    private func handlePing(from callsign: String) {
        // Respond with PingAck containing our SNR estimate
        onTransmitControl?(.ack)
    }

    private func handleBreak() {
        // Remote side requests immediate stop
        txQueue.removeAll()
        pendingFrames.removeAll()
        setState(.connected)
    }

    // MARK: - Data Framing

    private func sendNextDataFrame() {
        guard !txQueue.isEmpty else { return }
        setState(.sendingData)

        // Calculate max payload for current frame type
        let maxPayload = currentFrameType.netDataBytes

        // Extract chunk from queue
        let chunkSize = min(maxPayload, txQueue.count)
        let chunk = txQueue.prefix(chunkSize)
        txQueue = txQueue.dropFirst(chunkSize)

        // Track pending frame
        let seq = txSequence
        txSequence += 1
        pendingFrames.append((seq: seq, data: Data(chunk), retries: 0))

        // Send via callback
        onTransmitFrame?(Data(chunk), currentFrameType)
    }

    // MARK: - Adaptive Modulation

    private func adaptModulation(success: Bool) {
        if success {
            // Try upgrading if channel is good
            if channelQuality.frameErrorRate < 0.1 {
                upgradeModulation()
            }
        } else {
            // Downgrade on failure
            channelQuality.frameErrorRate = min(1.0, channelQuality.frameErrorRate + 0.2)
            downgradeModulation()
        }
    }

    private func upgradeModulation() {
        let types: [ARDOPFrameType] = [
            .fsk4_200_50S, .fsk4_200_50, .fsk4_500_100S, .fsk4_500_100,
            .psk4_200_100, .psk4_500_100, .psk4_1000_100,
            .psk8_1000_100, .psk4_2000_100, .psk8_2000_100, .qam16_2000_100
        ]
        if let idx = types.firstIndex(of: currentFrameType), idx < types.count - 1 {
            currentFrameType = types[idx + 1]
        }
    }

    private func downgradeModulation() {
        let types: [ARDOPFrameType] = [
            .fsk4_200_50S, .fsk4_200_50, .fsk4_500_100S, .fsk4_500_100,
            .psk4_200_100, .psk4_500_100, .psk4_1000_100,
            .psk8_1000_100, .psk4_2000_100, .psk8_2000_100, .qam16_2000_100
        ]
        if let idx = types.firstIndex(of: currentFrameType), idx > 0 {
            currentFrameType = types[idx - 1]
        }
    }

    private func updateChannelQuality(snr: Int?) {
        if let snr = snr {
            // Exponential moving average
            channelQuality.snr = channelQuality.snr * 0.7 + Double(snr) * 0.3
        }
        channelQuality.lastUpdate = Date()
    }

    // MARK: - Session Lifecycle

    private func setState(_ newState: ARDOPSessionState) {
        state = newState
        onStateChange?(newState)
    }

    private func cleanupSession() {
        txQueue.removeAll()
        rxBuffer.removeAll()
        pendingFrames.removeAll()
        txSequence = 0
        lastAckedSequence = -1
        remoteCallsign = nil
        channelQuality = ChannelQuality()
        setState(.disconnected)
    }
}

// MARK: - Session Statistics

extension ARDOPSession {
    /// Aktuelle Sitzungsstatistik
    struct SessionStats: Sendable {
        let state: ARDOPSessionState
        let remoteCallsign: String?
        let snr: Double
        let frameErrorRate: Double
        let currentMode: String
        let txQueueBytes: Int
        let rxBufferBytes: Int
        let pendingFrames: Int
    }

    func getStats() -> SessionStats {
        SessionStats(
            state: state,
            remoteCallsign: remoteCallsign,
            snr: channelQuality.snr,
            frameErrorRate: channelQuality.frameErrorRate,
            currentMode: "\(currentFrameType)",
            txQueueBytes: txQueue.count,
            rxBufferBytes: rxBuffer.count,
            pendingFrames: pendingFrames.count
        )
    }
}
