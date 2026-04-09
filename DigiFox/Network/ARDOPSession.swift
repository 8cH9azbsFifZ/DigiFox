/// ARDOP ARQ Session Management — connection layer above the physical layer.
///
/// Implements the ARQ (Automatic Repeat Request) protocol for reliable
/// data transmission over ARDOP. Manages connection setup, handshaking,
/// retransmission and adaptive modulation selection based on channel quality.
///
/// Key fixes vs. older version:
/// - Timeout enforcement for connection and idle timeouts
/// - Bandwidth constraint: modulation only within the negotiated bandwidth
/// - DISCACK response to DISC (ARDOP spec compliance)
/// - Frame type stays constant per frame (no re-modulation on NAK)
/// - Sequence validation on ACK
///
/// Reference: https://github.com/pflarue/ardop (ARDOP specification)
/// Reference: https://github.com/la5nta/wl2k-go/tree/master/transport/ardop

import Foundation

// MARK: - ARQ Session State Machine

/// State of the ARDOP ARQ session
enum ARDOPSessionState: String, Sendable {
    case disconnected = "Disconnected"
    case listening = "Listening"
    case connecting = "Connecting..."
    case connected = "Connected"
    case sendingData = "Sending data"
    case receivingData = "Receiving data"
    case disconnecting = "Disconnecting..."
    case failed = "Failed"
}

/// ARQ frame for session management
struct ARQFrame: Sendable {
    enum FrameKind: Sendable {
        case conReq(callsign: String, targetCallsign: String, bandwidth: ARDOPBandwidth)
        case conAck(callsign: String, bandwidth: ARDOPBandwidth)
        case disc
        case discAck
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

/// Channel quality metric for adaptive modulation
struct ChannelQuality: Sendable {
    var snr: Double = 0.0
    var frameErrorRate: Double = 0.0
    var throughput: Double = 0.0
    var lastUpdate: Date = Date()

    /// Recommended frame type based on channel quality
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

/// Thread-safe ARDOP ARQ session manager.
actor ARDOPSession {

    // MARK: - Configuration

    let myCallsign: String
    let maxBandwidth: ARDOPBandwidth
    let connectionTimeout: TimeInterval
    let idleTimeout: TimeInterval
    let maxRetries: Int

    // MARK: - State

    private(set) var state: ARDOPSessionState = .disconnected
    private(set) var remoteCallsign: String?
    private(set) var channelQuality = ChannelQuality()
    private(set) var currentFrameType: ARDOPFrameType = .fsk4_500_100

    /// Negotiated session bandwidth (agreed during handshake)
    private var sessionBandwidth: ARDOPBandwidth = .bw500

    private var txQueue = Data()
    private var rxBuffer = Data()
    private var txSequence: Int = 0
    private var lastAckedSequence: Int = -1
    /// Pending frames with their ORIGINAL frame type (not re-modulated on retransmit)
    private var pendingFrames: [(seq: Int, data: Data, frameType: ARDOPFrameType, retries: Int)] = []
    private var connectRetries: Int = 0

    /// Timestamps for timeout tracking
    private var connectionStartTime: Date?
    private var lastActivityTime: Date = Date()

    // MARK: - Callbacks

    var onStateChange: ((ARDOPSessionState) -> Void)?
    var onDataReceived: ((Data) -> Void)?
    var onTransmitFrame: ((Data, ARDOPFrameType) -> Void)?
    var onTransmitControl: ((ARDOPFrameType) -> Void)?

    // MARK: - Init

    init(callsign: String,
         bandwidth: ARDOPBandwidth = .bw500,
         timeout: TimeInterval = 120,
         idleTimeout: TimeInterval = 300,
         maxRetries: Int = 10) {
        self.myCallsign = callsign
        self.maxBandwidth = bandwidth
        self.connectionTimeout = timeout
        self.idleTimeout = idleTimeout
        self.maxRetries = maxRetries
        Log.d("ARQ", "Session created: call=\(callsign) bw=\(bandwidth) timeout=\(timeout)s")
    }

    // MARK: - Connection Management

    func connect(to targetCallsign: String) {
        guard state == .disconnected || state == .listening else {
            Log.d("ARQ", "connect: invalid state \(state)")
            return
        }
        remoteCallsign = targetCallsign
        connectRetries = 0
        connectionStartTime = Date()
        setState(.connecting)
        sendConnectRequest(to: targetCallsign)
        Log.d("ARQ", "Connection to \(targetCallsign) started")
    }

    func listen() {
        guard state == .disconnected else { return }
        setState(.listening)
        Log.d("ARQ", "Listening")
    }

    func disconnect() {
        guard state != .disconnected else { return }
        Log.d("ARQ", "Disconnect requested (state=\(state))")
        setState(.disconnecting)
        onTransmitControl?(.disc)
        cleanupSession()
    }

    // MARK: - Data Transfer

    func send(data: Data) {
        guard state == .connected else {
            Log.d("ARQ", "send: not connected (state=\(state))")
            return
        }
        Log.d("ARQ", "Enqueuing \(data.count) bytes in TX queue")
        txQueue.append(data)
        sendNextDataFrame()
    }

    func receiveAll() -> Data {
        let data = rxBuffer
        rxBuffer = Data()
        return data
    }

    var txQueueLength: Int { txQueue.count }
    var rxBufferLength: Int { rxBuffer.count }

    // MARK: - Timeout Check

    /// Checks for connection and idle timeouts. Should be called periodically.
    func checkTimeouts() {
        let now = Date()

        if state == .connecting, let start = connectionStartTime {
            if now.timeIntervalSince(start) > connectionTimeout {
                Log.d("ARQ", "Connection timeout after \(connectionTimeout)s")
                setState(.failed)
                cleanupSession()
                return
            }
        }

        if (state == .connected || state == .sendingData || state == .receivingData) {
            if now.timeIntervalSince(lastActivityTime) > idleTimeout {
                Log.d("ARQ", "Idle timeout after \(idleTimeout)s")
                disconnect()
            }
        }
    }

    // MARK: - Frame Processing

    func processReceivedFrame(_ frame: ARQFrame) {
        lastActivityTime = Date()

        switch frame.kind {
        case .conReq(let callsign, let target, let bandwidth):
            handleConReq(from: callsign, target: target, bandwidth: bandwidth)
        case .conAck(let callsign, let bandwidth):
            handleConAck(from: callsign, bandwidth: bandwidth)
        case .disc:
            handleDisconnect()
        case .discAck:
            Log.d("ARQ", "DISCACK received")
            cleanupSession()
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
        Log.d("ARQ", "TX ConReq: target=\(target) bw=\(maxBandwidth)")
        onTransmitControl?(bwType)
    }

    private func handleConReq(from callsign: String, target: String, bandwidth: ARDOPBandwidth) {
        guard state == .listening else {
            Log.d("ARQ", "ConReq ignored (state=\(state))")
            return
        }
        guard target.uppercased() == myCallsign.uppercased() else {
            Log.d("ARQ", "ConReq ignored (target=\(target), my=\(myCallsign))")
            return
        }

        remoteCallsign = callsign
        // Negotiate bandwidth: use minimum of requested and our max
        sessionBandwidth = bandwidth.rawValue < maxBandwidth.rawValue ? bandwidth : maxBandwidth
        currentFrameType = initialFrameType(for: sessionBandwidth)
        Log.d("ARQ", "ConReq accepted: from=\(callsign) bw=\(sessionBandwidth)")

        setState(.connected)

        // Send ConAck
        onTransmitControl?(.conAck)
    }

    private func handleConAck(from callsign: String, bandwidth: ARDOPBandwidth) {
        guard state == .connecting else { return }
        remoteCallsign = callsign
        sessionBandwidth = bandwidth
        currentFrameType = initialFrameType(for: sessionBandwidth)
        txSequence = 0
        lastAckedSequence = -1
        pendingFrames.removeAll()
        connectionStartTime = nil
        Log.d("ARQ", "Connected to \(callsign) (bw=\(bandwidth))")
        setState(.connected)
    }

    private func handleDisconnect() {
        Log.d("ARQ", "DISC received — sending DISCACK")
        // ARDOP spec: respond to DISC with DISCACK
        onTransmitControl?(.discAck)
        cleanupSession()
    }

    private func handleDataFrame(payload: Data, seq: Int, snr: Int?) {
        guard state == .connected || state == .receivingData else { return }
        setState(.receivingData)

        Log.d("ARQ", "RX Data: seq=\(seq) len=\(payload.count) snr=\(snr ?? -99)")
        rxBuffer.append(payload)
        onDataReceived?(payload)

        updateChannelQuality(snr: snr)
        onTransmitControl?(.ack)
        setState(.connected)
    }

    private func handleAck(seq: Int) {
        guard state == .connected || state == .sendingData else { return }

        // Validate sequence number
        guard seq >= 0, seq <= txSequence else {
            Log.d("ARQ", "ACK with invalid sequence \(seq) (txSeq=\(txSequence))")
            return
        }

        Log.d("ARQ", "ACK: seq=\(seq), pending=\(pendingFrames.count)")
        pendingFrames.removeAll { $0.seq <= seq }
        lastAckedSequence = seq

        adaptModulation(success: true)

        if !txQueue.isEmpty {
            sendNextDataFrame()
        } else if pendingFrames.isEmpty {
            setState(.connected)
        }
    }

    private func handleNak(seq: Int) {
        guard state == .connected || state == .sendingData else { return }

        guard let idx = pendingFrames.firstIndex(where: { $0.seq == seq }) else {
            Log.d("ARQ", "NAK for unknown sequence \(seq)")
            return
        }

        pendingFrames[idx].retries += 1
        Log.d("ARQ", "NAK: seq=\(seq) retry=\(pendingFrames[idx].retries)/\(maxRetries)")

        if pendingFrames[idx].retries >= maxRetries {
            Log.d("ARQ", "Max retries reached — session failed")
            setState(.failed)
            return
        }

        adaptModulation(success: false)

        // Retransmit with the ORIGINAL frame type (not current — data was encoded for original)
        let frame = pendingFrames[idx]
        onTransmitFrame?(frame.data, frame.frameType)
    }

    private func handlePing(from callsign: String) {
        Log.d("ARQ", "Ping from \(callsign)")
        onTransmitControl?(.ack)
    }

    private func handleBreak() {
        Log.d("ARQ", "BREAK received — TX queue cleared")
        txQueue.removeAll()
        pendingFrames.removeAll()
        setState(.connected)
    }

    // MARK: - Data Framing

    private func sendNextDataFrame() {
        guard !txQueue.isEmpty else { return }
        setState(.sendingData)

        let maxPayload = currentFrameType.netDataBytes
        let chunkSize = min(maxPayload, txQueue.count)
        let chunk = Data(txQueue.prefix(chunkSize))
        txQueue.removeFirst(chunkSize)

        let seq = txSequence
        txSequence += 1
        // Store frame with its frame type (for retransmission)
        pendingFrames.append((seq: seq, data: chunk, frameType: currentFrameType, retries: 0))

        Log.d("ARQ", "TX Data: seq=\(seq) len=\(chunk.count) type=\(currentFrameType)")
        onTransmitFrame?(chunk, currentFrameType)
    }

    // MARK: - Adaptive Modulation (bandwidth-constrained)

    private func adaptModulation(success: Bool) {
        if success {
            if channelQuality.frameErrorRate < 0.1 {
                upgradeModulation()
            }
            channelQuality.frameErrorRate = max(0, channelQuality.frameErrorRate - 0.05)
        } else {
            channelQuality.frameErrorRate = min(1.0, channelQuality.frameErrorRate + 0.2)
            downgradeModulation()
        }
    }

    /// Returns data frame types for the given bandwidth constraint.
    private func dataFrameTypes(for bandwidth: ARDOPBandwidth) -> [ARDOPFrameType] {
        switch bandwidth {
        case .bw200:
            return [.fsk4_200_50S, .fsk4_200_50, .psk4_200_100]
        case .bw500:
            return [.fsk4_200_50S, .fsk4_200_50, .fsk4_500_100S, .fsk4_500_100,
                    .psk4_200_100, .psk4_500_100]
        case .bw1000:
            return [.fsk4_200_50S, .fsk4_200_50, .fsk4_500_100S, .fsk4_500_100,
                    .psk4_200_100, .psk4_500_100, .psk4_1000_100, .psk8_1000_100]
        case .bw2000:
            return [.fsk4_200_50S, .fsk4_200_50, .fsk4_500_100S, .fsk4_500_100,
                    .psk4_200_100, .psk4_500_100, .psk4_1000_100, .psk8_1000_100,
                    .psk4_2000_100, .psk8_2000_100, .qam16_2000_100]
        }
    }

    private func initialFrameType(for bandwidth: ARDOPBandwidth) -> ARDOPFrameType {
        switch bandwidth {
        case .bw200:  return .fsk4_200_50S
        case .bw500:  return .fsk4_500_100S
        case .bw1000: return .psk4_500_100
        case .bw2000: return .psk4_1000_100
        }
    }

    private func upgradeModulation() {
        let types = dataFrameTypes(for: sessionBandwidth)
        if let idx = types.firstIndex(of: currentFrameType), idx < types.count - 1 {
            let old = currentFrameType
            currentFrameType = types[idx + 1]
            Log.d("ARQ", "Modulation upgrade: \(old) → \(currentFrameType)")
        }
    }

    private func downgradeModulation() {
        let types = dataFrameTypes(for: sessionBandwidth)
        if let idx = types.firstIndex(of: currentFrameType), idx > 0 {
            let old = currentFrameType
            currentFrameType = types[idx - 1]
            Log.d("ARQ", "Modulation downgrade: \(old) → \(currentFrameType)")
        }
    }

    private func updateChannelQuality(snr: Int?) {
        if let snr = snr {
            channelQuality.snr = channelQuality.snr * 0.7 + Double(snr) * 0.3
        }
        channelQuality.lastUpdate = Date()
    }

    // MARK: - Session Lifecycle

    private func setState(_ newState: ARDOPSessionState) {
        let old = state
        state = newState
        if old != newState {
            Log.d("ARQ", "State: \(old.rawValue) → \(newState.rawValue)")
        }
        onStateChange?(newState)
    }

    private func cleanupSession() {
        txQueue.removeAll()
        rxBuffer.removeAll()
        pendingFrames.removeAll()
        txSequence = 0
        lastAckedSequence = -1
        remoteCallsign = nil
        connectionStartTime = nil
        channelQuality = ChannelQuality()
        setState(.disconnected)
    }
}

// MARK: - Session Statistics

extension ARDOPSession {
    struct SessionStats: Sendable {
        let state: ARDOPSessionState
        let remoteCallsign: String?
        let snr: Double
        let frameErrorRate: Double
        let currentMode: String
        let sessionBandwidth: String
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
            sessionBandwidth: "\(sessionBandwidth)",
            txQueueBytes: txQueue.count,
            rxBufferBytes: rxBuffer.count,
            pendingFrames: pendingFrames.count
        )
    }
}
