import Foundation
import Network
import Combine
import os.log

private let logger = Logger(subsystem: "com.digifox.app", category: "HermesController")

/// High-level controller for Hermes SDR — coordinates protocol, IQ processing,
/// and audio pipeline integration. This is the primary interface for AppState.
actor HermesController {
    // State published via callback (can't use @Published in actor)
    var onAudioReceived: (([Float]) -> Void)?
    var onConnectionChanged: ((Bool) -> Void)?
    var onStatusUpdate: ((String) -> Void)?

    func setOnAudioReceived(_ handler: @escaping ([Float]) -> Void) {
        onAudioReceived = handler
    }

    func setOnConnectionChanged(_ handler: @escaping (Bool) -> Void) {
        onConnectionChanged = handler
    }

    func setOnStatusUpdate(_ handler: @escaping (String) -> Void) {
        onStatusUpdate = handler
    }

    private let protocol_ = HermesProtocol()
    private let iqProcessor: IQProcessor
    private let pathMonitor = NWPathMonitor(requiredInterfaceType: .wiredEthernet)
    private var ethernetAvailable = false

    // Configuration
    private(set) var device: HermesDevice?
    private(set) var connected = false
    private(set) var lnaGain: Int = 40
    private(set) var txPower: Int = 80  // percent

    init() {
        iqProcessor = IQProcessor(numReceivers: 1, swapIQ: true)

        // Monitor Ethernet availability
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { await self?.handlePathUpdate(available) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "hermes.pathmonitor"))
    }

    // MARK: - Connection

    /// Discover Hermes devices on the network
    func discoverDevices(directIP: String? = nil) async -> [HermesDevice] {
        let discovery = HermesDiscovery()
        return await discovery.discover(directIP: directIP)
    }

    /// Connect to a specific Hermes device
    func connect(to device: HermesDevice) async {
        self.device = device
        logger.info("Connecting to \(device.displayName)")

        await protocol_.connect(ip: device.ip, sampleRate: 48000, numReceivers: 1)

        // Wire EP6 callback for IQ processing
        await protocol_.setOnEP6Received { [weak self] data in
            Task { await self?.processEP6(data) }
        }

        await protocol_.setOnDisconnect { [weak self] in
            Task { await self?.handleDisconnect() }
        }

        await protocol_.start()

        connected = true
        onConnectionChanged?(true)
        onStatusUpdate?("Verbunden: \(device.displayName)")
        logger.info("Connected and streaming")
    }

    /// Disconnect from current device
    func disconnect() async {
        await protocol_.disconnect()
        connected = false
        device = nil
        onConnectionChanged?(false)
        onStatusUpdate?("Getrennt")
    }

    // MARK: - Rig Control

    func setFrequency(_ freqHz: Int) async {
        await protocol_.setRxFrequency(freqHz)
        await protocol_.setTxFrequency(freqHz)
        logger.debug("Frequency: \(freqHz) Hz")
    }

    func setLNAGain(_ gain: Int) async {
        lnaGain = gain
        await protocol_.setLNAGain(gain)
    }

    func setTxPower(_ percent: Int) async {
        txPower = percent
        let hwLevel = Int(Double(percent) * 255.0 / 100.0)
        await protocol_.setTxDriveLevel(hwLevel)
    }

    // MARK: - TX

    /// Transmit pre-modulated 12 kHz audio via Hermes.
    /// Converts to 48 kHz IQ and sends over UDP.
    func transmit(samples12k: [Float]) async {
        logger.info("TX: \(samples12k.count) samples @ 12 kHz")

        // Convert 12 kHz real audio → 48 kHz IQ
        let iq48k = IQProcessor.audioToTxIQ(samples12k)

        // Load into protocol (enables MOX automatically)
        await protocol_.loadTxAudio(iq48k)

        onStatusUpdate?("Sende...")

        // Wait for TX to complete (poll MOX state)
        while await protocol_.isTxActive {
            try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms
        }

        onStatusUpdate?("Gesendet")
        logger.info("TX complete")
    }

    /// Abort ongoing transmission
    func haltTx() async {
        await protocol_.clearTxAudio()
        onStatusUpdate?("TX abgebrochen")
    }

    // MARK: - IQ Processing

    private func processEP6(_ data: Data) {
        // Parse IQ from EP6 packet
        let iqArrays = iqProcessor.parseEP6Packet(data)
        guard let iq = iqArrays.first, !iq.isEmpty else { return }

        // Convert IQ to real audio
        let audio48k = IQProcessor.iqToAudio(iq)

        // Decimate to 12 kHz
        let audio12k = IQProcessor.decimateTo12kHz(audio48k, from: 48000)

        // Feed into audio engine pipeline
        onAudioReceived?(audio12k)
    }

    // MARK: - Network Monitoring

    private func handlePathUpdate(_ available: Bool) {
        let wasAvailable = ethernetAvailable
        ethernetAvailable = available

        if wasAvailable && !available && connected {
            logger.warning("Ethernet disconnected — stopping Hermes")
            Task { await disconnect() }
            onStatusUpdate?("Ethernet getrennt")
        }
    }

    private func handleDisconnect() {
        connected = false
        device = nil
        onConnectionChanged?(false)
        onStatusUpdate?("Verbindung verloren")
        logger.warning("Connection lost")
    }

    /// Whether Ethernet is currently available
    var isEthernetAvailable: Bool { ethernetAvailable }
}

// MARK: - HermesProtocol callback helpers (actor isolation bridge)

extension HermesProtocol {
    func setOnEP6Received(_ handler: @escaping (Data) -> Void) {
        self.onEP6Received = handler
    }

    func setOnDisconnect(_ handler: @escaping () -> Void) {
        self.onDisconnect = handler
    }
}
