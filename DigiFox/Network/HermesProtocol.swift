import Foundation
import Network
import os.log

private let logger = Logger(subsystem: "com.digifox.app", category: "HermesProtocol")

/// HPSDR Protocol 1 low-level UDP communication with Hermes SDR.
/// Handles EP2 (control → SDR) and EP6 (IQ data ← SDR).
actor HermesProtocol {
    // Configuration
    private(set) var ip: String = ""
    private(set) var sampleRate: Int = 48000
    private(set) var numReceivers: Int = 1
    private(set) var lnaGain: Int = 40

    // State
    private var connection: NWConnection?
    private var running = false
    private var seqTx: UInt32 = 0
    private var c0Index = 0
    private var cycleLen = 6
    private var mox = false
    private var txFreq: Int = 7_074_000
    private var rxFreqs: [Int] = [7_074_000]
    private var txDriveLevel: Int = 200

    // TX audio buffer (interleaved I/Q at 48 kHz)
    private var txAudioBuffer: [Float]?
    private var txAudioPos: Int = 0

    // Keepalive timer
    private var keepaliveTask: Task<Void, Never>?

    // Callbacks
    var onEP6Received: ((Data) -> Void)?
    var onPTTChanged: ((Bool) -> Void)?
    var onDisconnect: (() -> Void)?

    // Telemetry
    private(set) var rxPacketCount: Int = 0
    private(set) var lastPTT: Bool = false

    // Speed encoding for EP2
    private static let speedBits: [Int: UInt8] = [48000: 0x00, 96000: 0x01, 192000: 0x02, 384000: 0x03]

    // MARK: - Connection Lifecycle

    func connect(ip: String, sampleRate: Int = 48000, numReceivers: Int = 1) {
        self.ip = ip
        self.sampleRate = sampleRate
        self.numReceivers = numReceivers
        self.cycleLen = max(6, 4 + numReceivers)
        self.rxFreqs = Array(repeating: 7_074_000, count: numReceivers)

        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(ip), port: NWEndpoint.Port(rawValue: kMetisPort)!)
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        connection = NWConnection(to: endpoint, using: params)
        connection?.start(queue: DispatchQueue(label: "hermes.protocol"))
        logger.info("Connected to \(ip):\(kMetisPort)")
    }

    func start() async {
        guard let conn = connection else {
            logger.error("start() called without connection")
            return
        }

        // Send stop first (in case of previous crash)
        let stopPacket = Data([0xEF, 0xFE, 0x04, 0x00]) + Data(count: 60)
        conn.send(content: stopPacket, completion: .contentProcessed { _ in })
        try? await Task.sleep(nanoseconds: 50_000_000)

        // Start: 0xEFFE04 + 0x81 (Run + IQ)
        let startPacket = Data([0xEF, 0xFE, 0x04, 0x81]) + Data(count: 60)
        conn.send(content: startPacket, completion: .contentProcessed { _ in })

        running = true
        rxPacketCount = 0
        seqTx = 0
        c0Index = 0

        // Send first EP2 immediately
        sendEP2()

        // Start keepalive loop (~50ms interval for C&C cycle)
        keepaliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms
                await self?.keepaliveTick()
            }
        }

        // Start receive loop
        startReceiveLoop()
        logger.info("SDR started (rate=\(self.sampleRate), nrx=\(self.numReceivers))")
    }

    func stop() {
        guard running else { return }

        // Force MOX off
        if mox {
            mox = false
            sendEP2()
        }

        running = false
        keepaliveTask?.cancel()
        keepaliveTask = nil

        let stopPacket = Data([0xEF, 0xFE, 0x04, 0x00]) + Data(count: 60)
        connection?.send(content: stopPacket, completion: .contentProcessed { _ in })
        logger.info("SDR stopped")
    }

    func disconnect() {
        stop()
        connection?.cancel()
        connection = nil
        logger.info("Disconnected")
    }

    // MARK: - Control

    func setRxFrequency(_ freqHz: Int, rxIndex: Int = 0) {
        guard rxIndex < rxFreqs.count else { return }
        rxFreqs[rxIndex] = freqHz
    }

    func setTxFrequency(_ freqHz: Int) {
        txFreq = freqHz
    }

    func setMOX(_ on: Bool) {
        mox = on
        logger.debug("MOX \(on ? "ON" : "OFF")")
    }

    func setLNAGain(_ gain: Int) {
        lnaGain = max(0, min(60, gain))
    }

    func setTxDriveLevel(_ level: Int) {
        txDriveLevel = max(0, min(255, level))
    }

    /// Load TX IQ audio buffer. Enables MOX automatically.
    /// Buffer is interleaved [I, Q, I, Q, ...] at 48 kHz.
    func loadTxAudio(_ iq48k: [Float]) {
        txAudioBuffer = iq48k
        txAudioPos = 0
        mox = true
        logger.info("TX audio loaded: \(iq48k.count / 2) IQ samples")
    }

    func clearTxAudio() {
        txAudioBuffer = nil
        txAudioPos = 0
        mox = false
    }

    // MARK: - EP2 Packet Building

    private func keepaliveTick() {
        guard running else { return }

        // If TX audio is loaded, send faster (~3.5ms per packet = 48kHz)
        if txAudioBuffer != nil {
            sendEP2()
        } else {
            sendEP2()
        }
    }

    private func sendEP2() {
        guard let conn = connection else { return }

        var packet = Data(count: 1032)

        // Metis header
        packet[0] = 0xEF
        packet[1] = 0xFE
        packet[2] = 0x01  // data
        packet[3] = 0x02  // EP2

        // Sequence number (big-endian)
        packet[4] = UInt8((seqTx >> 24) & 0xFF)
        packet[5] = UInt8((seqTx >> 16) & 0xFF)
        packet[6] = UInt8((seqTx >> 8) & 0xFF)
        packet[7] = UInt8(seqTx & 0xFF)
        seqTx += 1

        // Build two USB frames
        buildUSBFrame(into: &packet, at: kMetisHeaderSize)
        buildUSBFrame(into: &packet, at: kMetisHeaderSize + kUSBFrameSize)

        conn.send(content: packet, completion: .contentProcessed { error in
            if let error = error {
                logger.error("EP2 send error: \(error.localizedDescription)")
            }
        })
    }

    private func buildUSBFrame(into packet: inout Data, at offset: Int) {
        // Sync bytes
        packet[offset] = 0x7F
        packet[offset + 1] = 0x7F
        packet[offset + 2] = 0x7F

        // C0-C4 based on cycle index
        let (c0, c1, c2, c3, c4) = registerForCycleIndex(c0Index)
        packet[offset + 3] = c0
        packet[offset + 4] = c1
        packet[offset + 5] = c2
        packet[offset + 6] = c3
        packet[offset + 7] = c4

        // TX audio payload (if MOX and we have audio)
        if mox, let buffer = txAudioBuffer {
            let samplesPerFrame = 504 / 6  // 84 samples per frame, 6 bytes each (3 I + 3 Q)
            let payloadStart = offset + 8

            for i in 0..<samplesPerFrame {
                let bufIdx = txAudioPos + i
                let byteOffset = payloadStart + i * 6

                if bufIdx * 2 + 1 < buffer.count {
                    let iVal = buffer[bufIdx * 2]
                    let qVal = buffer[bufIdx * 2 + 1]

                    // Convert float [-1, 1] to 24-bit signed
                    let iInt = Int32(iVal * 8388607.0)
                    let qInt = Int32(qVal * 8388607.0)

                    packet[byteOffset] = UInt8((iInt >> 16) & 0xFF)
                    packet[byteOffset + 1] = UInt8((iInt >> 8) & 0xFF)
                    packet[byteOffset + 2] = UInt8(iInt & 0xFF)
                    packet[byteOffset + 3] = UInt8((qInt >> 16) & 0xFF)
                    packet[byteOffset + 4] = UInt8((qInt >> 8) & 0xFF)
                    packet[byteOffset + 5] = UInt8(qInt & 0xFF)
                }
            }
            txAudioPos += samplesPerFrame

            // Check if buffer is exhausted
            if txAudioPos * 2 >= buffer.count {
                txAudioBuffer = nil
                txAudioPos = 0
                mox = false
                logger.info("TX audio complete — MOX off")
            }
        }

        // Advance cycle
        c0Index = (c0Index + 1) % cycleLen
    }

    private func registerForCycleIndex(_ idx: Int) -> (UInt8, UInt8, UInt8, UInt8, UInt8) {
        let speedBit = Self.speedBits[sampleRate] ?? 0x00
        let nrxBits = UInt8(numReceivers - 1)

        switch idx {
        case 0:
            // General config + MOX
            let c0: UInt8 = mox ? 0x01 : 0x00
            let c1 = speedBit
            let c2: UInt8 = 0x00
            let c3: UInt8 = nrxBits & 0x07
            let c4: UInt8 = ((nrxBits & 0x38) << 3) | 0x04  // duplex=1
            return (c0, c1, c2, c3, c4)

        case 1:
            // TX NCO frequency
            let freq = UInt32(txFreq)
            return (0x02,
                    UInt8((freq >> 24) & 0xFF),
                    UInt8((freq >> 16) & 0xFF),
                    UInt8((freq >> 8) & 0xFF),
                    UInt8(freq & 0xFF))

        case 2:
            // RX1 NCO frequency
            let freq = UInt32(rxFreqs[0])
            return (0x04,
                    UInt8((freq >> 24) & 0xFF),
                    UInt8((freq >> 16) & 0xFF),
                    UInt8((freq >> 8) & 0xFF),
                    UInt8(freq & 0xFF))

        case 3:
            // RX2 NCO (or repeat RX1 if only 1 receiver)
            let freq = UInt32(numReceivers > 1 ? rxFreqs[1] : rxFreqs[0])
            return (0x06,
                    UInt8((freq >> 24) & 0xFF),
                    UInt8((freq >> 16) & 0xFF),
                    UInt8((freq >> 8) & 0xFF),
                    UInt8(freq & 0xFF))

        case 4:
            // TX drive level
            let drive = UInt8(txDriveLevel >> 4)  // Top 4 bits
            return (0x12, drive << 4, 0x00, 0x00, 0x00)

        case 5:
            // LNA gain (AD9866 extended mode: bit 6 = 1, bits 5:0 = gain)
            let gainByte = UInt8(0x40) | UInt8(lnaGain & 0x3F)
            return (0x14, 0x00, 0x00, 0x00, gainByte)

        default:
            return (0x00, 0x00, 0x00, 0x00, 0x00)
        }
    }

    // MARK: - EP6 Receive

    private func startReceiveLoop() {
        guard let conn = connection else { return }

        func receive() {
            conn.receiveMessage { [weak self] data, _, _, error in
                guard let self = self else { return }

                if let error = error {
                    logger.error("Receive error: \(error.localizedDescription)")
                    Task { await self.handleDisconnect() }
                    return
                }

                if let data = data {
                    Task { await self.handleEP6(data) }
                }

                // Continue receiving
                Task {
                    let stillRunning = await self.isRunning
                    if stillRunning { receive() }
                }
            }
        }
        receive()
    }

    private var isRunning: Bool { running }

    private func handleEP6(_ data: Data) {
        // Validate EP6 header
        guard data.count >= kEP6PacketSize,
              data[0] == 0xEF, data[1] == 0xFE,
              data[2] == 0x01, data[3] == 0x06 else { return }

        rxPacketCount += 1

        // Parse PTT status
        let c0 = data[kMetisHeaderSize + 3]
        let ptt = (c0 & 0x01) != 0
        if ptt != lastPTT {
            lastPTT = ptt
            onPTTChanged?(ptt)
        }

        // Forward to callback
        onEP6Received?(data)
    }

    private func handleDisconnect() {
        running = false
        keepaliveTask?.cancel()
        onDisconnect?()
    }
}
