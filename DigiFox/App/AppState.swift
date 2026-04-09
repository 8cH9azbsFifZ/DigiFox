import Foundation
import Combine
import os.log

private let logger = Logger(subsystem: "com.digifox.app", category: "AppState")

enum DigitalMode: Int, CaseIterable, Identifiable {
    case ft8 = 0
    case js8 = 1
    case cw = 4
    case wspr = 5
    case winlink = 6
    var id: Int { rawValue }
    var name: String {
        switch self {
        case .ft8:     return "FT8"
        case .js8:     return "JS8Call"
        case .cw:      return "CW"
        case .wspr:    return "WSPR"
        case .winlink: return "Winlink"
        }
    }
}

@MainActor
class AppState: ObservableObject {
    // MARK: - Shared State
    @Published var rxMessages = [RxMessage]()
    @Published var stations = [Station]()
    @Published var waterfallData = [[Float]]()
    @Published var isReceiving = false
    @Published var isTransmitting = false
    @Published var statusText = "Ready"
    @Published var radioState = RadioState()
    @Published var usbDevices = [SerialDeviceInfo]()
    @Published var ioKitAvailable = false

    // MARK: - FT8 State
    @Published var txFrequency: Double = 1500.0
    @Published var txEnabled = false
    @Published var txEven = true
    @Published var selectedTxMessage = 0
    @Published var autoSequence = true
    @Published var dxCall = ""
    @Published var dxGrid = ""
    @Published var dxReport = "+00"
    @Published var txMessages = ["", "", "", "", "", ""]
    @Published var qsoLog = [QSOLogEntry]()

    // MARK: - JS8 State
    @Published var txMessage = TxMessage()

    // MARK: - WSPR State
    @Published var wsprPower: Int = 30  // dBm
    @Published var wsprTxEnabled = false

    // MARK: - CW State
    @Published var cwText = ""
    @Published var cwSpeed: Int = 20
    @Published var cwLog = [String]()
    @Published var cwDecodedText = ""
    @Published var cwDecoding = false

    let settings = AppSettings()
    let audioEngine = AudioEngine()
    let catController = CATController()
    let morseKeyer = MorseKeyer()
    private var cwDecoder: GGMorseDecoder
    let trusdxAudio = TruSDXSerialAudio()
    private var trusdxPort: SerialPort?

    private let ft8Modulator = FT8Modulator()
    private let ft8Demodulator = FT8Demodulator()
    private let js8Modulator = JS8Modulator()
    private let js8Demodulator = JS8Demodulator()
    private let wsprModulator = WSPRModulator()
    private let wsprDemodulator = WSPRDemodulator()
    private let ardopModulator = ARDOPModulator()
    private let ardopDemodulator = ARDOPDemodulator()
    private var cancellables = Set<AnyCancellable>()
    private var demodTask: Task<Void, Never>?
    private var usbScanTask: Task<Void, Never>?
    private var cycleTask: Task<Void, Never>?
    private var rigPollTask: Task<Void, Never>?
    private var txTask: Task<Void, Never>?

    // Spot reporters (ported from wave-owl)
    private var pskReporter: PSKReporter?
    private var rbnReporter: RBNReporter?
    private var wsprNetReporter: WSPRNetReporter?

    init() {
        // DX call/grid start empty (no QSO partner yet)
        dxCall = ""
        dxGrid = ""
        // Initial CW decoder (ggmorse) at default rate
        cwDecoder = GGMorseDecoder(sampleRate: 12000)
        setupBindings()
        #if targetEnvironment(simulator)
        ioKitAvailable = true
        Log.d("App", "Running in Simulator — IOKit bridged from macOS")
        #else
        ioKitAvailable = SerialPort.isAvailable
        Log.d("App", "IOKit available: \(ioKitAvailable)")
        #endif
        startUSBMonitoring()
        updateTxMessages()
        startReceiving()
        setupSpotReporters()
        Log.d("App", "AppState initialized — callsign=\(settings.callsign) grid=\(settings.grid)")
    }

    private func setupBindings() {
        audioEngine.$isTransmitting.assign(to: &$isTransmitting)
        audioEngine.$spectrumData
            .filter { !$0.isEmpty }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] s in self?.addWaterfallRow(s) }
            .store(in: &cancellables)
        $dxCall.sink { [weak self] _ in self?.updateTxMessages() }.store(in: &cancellables)
        $dxGrid.sink { [weak self] _ in self?.updateTxMessages() }.store(in: &cancellables)
        $dxReport.sink { [weak self] _ in self?.updateTxMessages() }.store(in: &cancellables)
        // Re-build TX messages when callsign or grid changes in UserDefaults
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateTxMessages() }
            .store(in: &cancellables)
    }

    // MARK: - FT8 TX Messages (WSJT-X style)

    func updateTxMessages() {
        let my = settings.callsign
        let myGrid = String(settings.grid.prefix(4))
        let dx = dxCall.isEmpty ? "..." : dxCall
        txMessages = [
            "CQ \(my) \(myGrid)",
            "\(dx) \(my) \(myGrid)",
            "\(dx) \(my) \(dxReport)",
            "\(dx) \(my) RRR",
            "\(dx) \(my) 73",
            "",
        ]
    }

    func startQSO(with callsign: String, grid: String = "") {
        dxCall = callsign; dxGrid = grid
        selectedTxMessage = 1; txEnabled = true
        updateTxMessages()
    }

    func logQSO() {
        guard !dxCall.isEmpty else { return }
        let entry = QSOLogEntry(
            timestamp: Date(), callsign: dxCall, grid: dxGrid,
            frequency: settings.dialFrequency + txFrequency,
            report: dxReport, mode: settings.digitalMode.name
        )
        qsoLog.insert(entry, at: 0)
        statusText = "QSO logged: \(dxCall)"
    }

    private func advanceFT8Sequence() {
        guard autoSequence else { return }
        if selectedTxMessage < 4 { selectedTxMessage += 1; updateTxMessages() }
        else { txEnabled = false; statusText = "QSO complete" }
    }

    /// Immediately halt any ongoing TX — cancel task, send RX; to TruSDX
    func haltTx() {
        Log.d("TX-HALT", "haltTx() called — txEnabled=\(txEnabled) isTransmitting=\(isTransmitting) txTask=\(txTask != nil) cwKeying=\(cwKeying)")
        txEnabled = false

        // Stop monitor audio playback
        audioEngine.stopPlayback()

        if let task = txTask {
            Log.d("TX-HALT", "Cancelling TX task")
            task.cancel()
            txTask = nil
        }

        // If TruSDX is transmitting, force RX immediately via direct POSIX write
        // (async port.write would queue behind sendAudio chunks — too slow)
        if isTruSDX, let port = trusdxPort, isTransmitting {
            let fd = port.rawFD
            if fd >= 0 {
                Log.d("TX-HALT", "TruSDX: direct POSIX write RX; on fd=\(fd)")
                let rx = Array(";RX;".utf8)
                rx.withUnsafeBufferPointer { _ = Darwin.write(fd, $0.baseAddress!, $0.count) }
            } else {
                Log.d("TX-HALT", "TruSDX: WARNING — fd invalid (\(fd)), falling back to async")
                Task { try? await port.write(";RX;") }
            }
            // Resume streaming after short delay
            Task {
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms for RX; to be processed
                Log.d("TX-HALT", "TruSDX: resuming streaming")
                trusdxAudio.startStreaming()
            }
            isTransmitting = false
            statusText = "TX abgebrochen"
        }

        // CW keying
        if cwKeying { stopCW() }
    }

    // MARK: - Rig Control

    func connectRig() {
        guard settings.useHamlib else { statusText = "No rig model selected"; Log.d("RIG", "Connect aborted — no rig model selected"); return }
        let baudRate = settings.radioProfile == .trusdx ? settings.radioProfile.defaultBaudRate : settings.rigSerialRate
        let modelId = settings.radioProfile == .trusdx ? settings.radioProfile.defaultHamlibModel : settings.rigModel
        Log.d("RIG", "Connecting: profile=\(settings.radioProfile.rawValue) model=\(modelId) baud=\(baudRate)")
        Task {
            do {
                let devices = SerialPort.discoverDevices()

                // Pick the right device based on radio profile
                let device: SerialDeviceInfo?
                if settings.radioProfile == .trusdx {
                    device = devices.first { $0.isTruSDX } ?? devices.first
                } else {
                    device = devices.first { $0.isDigirig } ?? devices.first
                }

                guard let dev = device else { statusText = "No USB serial device found"; return }

                if isTruSDX {
                    // TruSDX: open separate SerialPort for audio streaming
                    Log.d("Connect", "TruSDX: opening port \(dev.path) @ \(baudRate)")
                    let port = SerialPort()
                    try await port.open(path: dev.path, baudRate: UInt(baudRate))
                    trusdxPort = port
                    trusdxAudio.attach(to: port)
                    Log.d("Connect", "TruSDX: port opened, rawFD=\(port.rawFD)")

                    // Send initial CAT commands directly
                    try await port.write("ID;")   // verify connection
                    let rigMode = settings.digitalMode == .cw ? "MD3;" : "MD2;"
                    Log.d("Connect", "TruSDX: sending \(rigMode)")
                    try await port.write(rigMode)
                    if let freq = BandPlan.dialFrequency(band: settings.selectedBand, mode: settings.digitalMode) {
                        let freqCmd = String(format: "FA%011d;", Int(freq))
                        Log.d("Connect", "TruSDX: sending \(freqCmd)")
                        try await port.write(freqCmd)
                    }

                    // Wire RX audio to decoders (BEFORE starting stream to avoid race)
                    let upsampledRate = 12000.0
                    trusdxAudio.onAudioReceived = { [weak self] samples in
                        guard let self else { return }
                        let upsampled = TruSDXSerialAudio.upsample(samples, to: upsampledRate)
                        self.audioEngine.feedExternalSamples(upsampled, sampleRate: upsampledRate)
                    }

                    // Start audio streaming
                    Log.d("Connect", "TruSDX: starting audio streaming")
                    trusdxAudio.startStreaming()

                    radioState.isConnected = true
                    radioState.rigName = "(tr)uSDX"
                    statusText = "Connected: (tr)uSDX (Serial)"
                } else {
                    try await catController.connect(modelId: modelId, path: dev.path, baudRate: baudRate)

                    // FT8 and JS8Call require USB mode
                    try await catController.setMode("USB")

                    // Set dial frequency for current band/mode
                    if let freq = BandPlan.dialFrequency(band: settings.selectedBand, mode: settings.digitalMode) {
                        try await catController.setFrequency(UInt64(freq))
                    }

                    radioState = await catController.state
                    statusText = "Connected: \(radioState.rigName) (USB)"
                    startRigPolling()
                }
            } catch { statusText = "Rig error: \(error.localizedDescription)"; Log.d("RIG-ERROR", "\(error.localizedDescription)") }
        }
    }

    func disconnectRig() {
        Log.d("RIG", "Disconnecting rig")
        rigPollTask?.cancel(); rigPollTask = nil
        if isTruSDX {
            trusdxAudio.stopStreaming()
            trusdxAudio.detach()
            Task { await trusdxPort?.close() }
            trusdxPort = nil
            radioState = RadioState()
            statusText = "Rig disconnected"
        } else {
            Task { await catController.disconnect(); radioState = await catController.state; statusText = "Rig disconnected" }
        }
    }

    /// Switch digital mode: update dial frequency, rig mode, and restart decode loop.
    /// Always ensures rig frequency and mode match the selected tab.
    func switchMode(_ mode: DigitalMode) {
        let modeChanged = settings.digitalMode != mode
        settings.digitalMode = mode

        if modeChanged {
            // Stop current decode/demod task
            demodTask?.cancel(); demodTask = nil
            cycleTask?.cancel(); cycleTask = nil
            cwDecoding = false
        }

        // Always set rig frequency and mode when connected
        if radioState.isConnected {
            if let freq = BandPlan.dialFrequency(band: settings.selectedBand, mode: mode) {
                setRigFrequency(UInt64(freq))
            }
            if isTruSDX, let port = trusdxPort {
                let modeCmd = mode == .cw ? "MD3;" : "MD2;"
                Task {
                    // Stop streaming, change mode, restart streaming
                    Log.d("Mode", "TruSDX: stop streaming → \(modeCmd) → restart streaming")
                    self.trusdxAudio.stopStreaming()
                    try? await Task.sleep(nanoseconds: 50_000_000) // 50ms settle
                    try? await port.write(modeCmd)
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    self.trusdxAudio.startStreaming()
                }
            } else {
                let rigMode = mode == .cw ? "CW" : "USB"
                Task { try? await catController.setMode(rigMode) }
            }
        }

        // Start appropriate decode loop (restart if mode changed, ensure running if not)
        if isReceiving && (modeChanged || demodTask == nil && cycleTask == nil) {
            demodTask?.cancel(); demodTask = nil
            cycleTask?.cancel(); cycleTask = nil
            switch mode {
            case .ft8: startFT8Cycle()
            case .js8: startJS8DemodLoop()
            case .cw:  startCWDecodeLoop()
            case .wspr: startWSPRCycle()
            case .winlink: break  // ARDOP ARQ session — future implementation
            }
            Log.d("Mode", "\(mode): freq/mode set, decode loop started")
        }
    }

    /// Periodically poll rig for frequency and mode changes (every 500ms).
    /// Syncs rig state back to the UI so dial display stays current.
    private func startRigPolling() {
        rigPollTask?.cancel()
        rigPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
                guard let self, await self.catController.isConnected else { break }
                do {
                    let freq = try await self.catController.getFrequency()
                    let mode = try await self.catController.getMode()
                    await MainActor.run {
                        self.settings.dialFrequency = Double(freq)
                        self.radioState.frequency = freq
                        self.radioState.mode = mode
                        // Update selected band to match rig frequency
                        if let band = BandPlan.band(for: Double(freq)) {
                            self.settings.selectedBand = band.id
                        }
                    }
                } catch {
                    // Polling failed — rig may have been disconnected
                    Log.d("RIG-ERROR", "Polling failed: \(error.localizedDescription)")
                    await MainActor.run { self.radioState.isConnected = false; self.statusText = "Rig connection lost" }
                    break
                }
            }
        }
    }

    func setRigFrequency(_ hz: UInt64) {
        Log.d("RIG", "setRigFrequency: \(hz) Hz (\(String(format: "%.6f", Double(hz)/1_000_000)) MHz)")
        if isTruSDX, let port = trusdxPort {
            let cmd = String(format: "FA%011d;", hz)
            Log.d("RIG", "TruSDX: sending \(cmd)")
            Task { try? await port.write(cmd) }
            settings.dialFrequency = Double(hz)
            radioState.frequency = hz
        } else {
            Task {
                do {
                    try await catController.setFrequency(hz)
                    settings.dialFrequency = Double(hz)
                    radioState.frequency = hz
                }
                catch { statusText = "Frequency error: \(error.localizedDescription)" }
            }
        }
    }

    // MARK: - USB Monitoring

    func scanUSBDevices() {
        let prev = usbDevices
        usbDevices = SerialPort.discoverDevices()
        if usbDevices.count != prev.count {
            Log.d("USB", "Scan: \(usbDevices.count) device(s) found")
        }
        for d in usbDevices.filter({ d in !prev.contains(where: { $0.path == d.path }) }) {
            Log.d("USB", "New device: \(d.name) path=\(d.path) VID=0x\(String(d.vendorID, radix: 16)) PID=0x\(String(d.productID, radix: 16))")
            statusText = d.isDigirig ? "🔌 Digirig detected: \(d.path)" : "🔌 USB device: \(d.name)"
        }
        for d in prev.filter({ d in !usbDevices.contains(where: { $0.path == d.path }) }) {
            Log.d("USB", "Device removed: \(d.name) path=\(d.path)")
        }
    }

    var digirigConnected: Bool { usbDevices.contains { $0.isDigirig } }
    var trusdxConnected: Bool { usbDevices.contains { $0.isTruSDX } }
    var isTruSDX: Bool { settings.radioProfile == .trusdx }
    var hasCompatibleDevice: Bool {
        switch settings.radioProfile {
        case .trusdx: return trusdxConnected || !usbDevices.isEmpty
        case .digirig, .digirigVOX: return digirigConnected || !usbDevices.isEmpty
        }
    }

    private func startUSBMonitoring() {
        scanUSBDevices()
        usbScanTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                self?.scanUSBDevices()
            }
        }
    }

    // MARK: - RX/TX

    func startReceiving() {
        Log.d("App", "startReceiving: mode=\(settings.digitalMode.name) hasRig=\(radioState.isConnected)")
        if settings.useHamlib && !radioState.isConnected && hasCompatibleDevice { connectRig() }
        if !isTruSDX {
            audioEngine.start()
        }
        switch settings.digitalMode {
        case .ft8: startFT8Cycle()
        case .js8: startJS8DemodLoop()
        case .cw:  startCWDecodeLoop()
        case .wspr: startWSPRCycle()
        case .winlink: break  // ARDOP ARQ session — future implementation
        }
        isReceiving = true
        statusText = radioState.isConnected ? "Receiving (rig connected)" : "Receiving..."
    }

    func stopReceiving() {
        Log.d("App", "stopReceiving")
        if !isTruSDX { audioEngine.stop() }
        demodTask?.cancel(); demodTask = nil
        cycleTask?.cancel(); cycleTask = nil
        rigPollTask?.cancel(); rigPollTask = nil
        if radioState.isConnected { disconnectRig() }
        isReceiving = false; txEnabled = false
        statusText = "Stopped"
    }

    // MARK: - FT8 Cycle

    private func startFT8Cycle() {
        cycleTask = Task { [weak self] in
            while !Task.isCancelled {
                let now = Date()
                let second = Calendar.current.component(.second, from: now)
                let nano = Calendar.current.component(.nanosecond, from: now)
                let currentPos = Double(second % 15) + Double(nano) / 1_000_000_000
                let waitTime = 15.0 - currentPos + 0.5
                try? await Task.sleep(nanoseconds: UInt64(waitTime * 1_000_000_000))
                await self?.runFT8Demodulation()
                let secAfter = Calendar.current.component(.second, from: Date())
                let isEvenSlot = (secAfter / 15) % 2 == 0
                if self?.txEnabled == true && isEvenSlot == self?.txEven {
                    Log.d("FT8", "TX slot triggered — txEnabled=true, isEvenSlot=\(isEvenSlot), txEven=\(self?.txEven ?? false), isTransmitting=\(self?.isTransmitting ?? false)")
                    await self?.transmitFT8()
                }
            }
        }
    }

    private func runFT8Demodulation() {
        let samples = audioEngine.getBufferedSamples()
        let needed = FT8Protocol.symbolSamples * FT8Protocol.symbolCount
        Log.d("FT8-RX", "runFT8Demodulation: \(samples.count) samples buffered, need \(needed), hwRate=\(audioEngine.hardwareSampleRate)")
        guard samples.count > needed else {
            Log.d("FT8-RX", "Not enough samples — skipping decode")
            return
        }
        // Compute RMS to verify audio level
        let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
        Log.d("FT8-RX", "Audio RMS=\(String(format: "%.6f", rms)) (\(samples.count) samples)")
        Task.detached { [weak self, demodulator = self.ft8Demodulator] in
            let results = demodulator.demodulate(samples)
            Log.d("FT8-RX", "Demodulator returned \(results.count) decoded messages")
            await MainActor.run {
                for r in results {
                    let msg = RxMessage(
                        timestamp: Date(), frequency: r.frequency, snr: Int(r.snr),
                        deltaTime: r.timeOffset, text: r.message.displayText,
                        mode: .ft8, ft8Message: r.message,
                        isCQ: r.message.type == .cq,
                        isMyCall: r.message.to?.uppercased() == self?.settings.callsign.uppercased()
                    )
                    self?.rxMessages.insert(msg, at: 0)
                    if (self?.rxMessages.count ?? 0) > 200 { self?.rxMessages.removeLast() }
                    self?.reportSpot(msg)
                    if let call = r.message.from {
                        self?.updateStation(callsign: call, grid: r.message.grid ?? "", frequency: r.frequency, snr: Int(r.snr))
                    }
                    if r.message.to?.uppercased() == self?.settings.callsign.uppercased() {
                        self?.handleIncomingFT8QSO(r.message)
                    }
                }
            }
        }
        audioEngine.clearBuffer()
    }

    private func handleIncomingFT8QSO(_ msg: FT8Message) {
        guard autoSequence, let from = msg.from else { return }
        dxCall = from
        if let grid = msg.grid, !grid.isEmpty { dxGrid = grid }
        switch msg.type {
        case .cq: break
        case .response:
            if let report = msg.report { dxReport = report }
            selectedTxMessage = 2
        case .confirm: selectedTxMessage = 4
        default: break
        }
        updateTxMessages()
    }

    private func transmitFT8() {
        guard selectedTxMessage < txMessages.count else { Log.d("FT8-TX", "selectedTxMessage out of range"); return }
        let msgText = txMessages[selectedTxMessage]
        guard !msgText.isEmpty else { Log.d("FT8-TX", "empty message text"); return }
        Log.d("FT8-TX", "transmitFT8: msg='\(msgText)' txFreq=\(txFrequency) dialFreq=\(settings.dialFrequency) isTruSDX=\(isTruSDX)")
        statusText = "Sending: \(msgText)"
        let ft8Msg = FT8MessagePack.parseText(msgText, myCall: settings.callsign, myGrid: settings.grid)
        ft8Modulator.baseFrequency = txFrequency
        let samples = ft8Modulator.modulate(ft8Msg)

        if isTruSDX, let port = trusdxPort {
            // TruSDX: send audio over serial (CAT streaming)
            isTransmitting = true
            // Monitor: play FT8 tone on speaker for debugging (non-critical)
            do {
                Log.d("FT8-TX", "Playing monitor audio on speaker (\(samples.count) samples @ 12kHz)")
                audioEngine.transmit(samples: samples, completion: nil)
            } catch {
                Log.d("FT8-TX", "Monitor playback failed (non-critical): \(error)")
            }
            txTask = Task {
                do {
                    Log.d("FT8-TX", "TruSDX: setting USB mode (MD2;)")
                    try await port.write("MD2;")
                    Log.d("FT8-TX", "TruSDX: keying TX (TX0;)")
                    try await port.write(";TX0;")
                    try await Task.sleep(nanoseconds: 50_000_000) // 50ms settling
                    Log.d("FT8-TX", "TruSDX: sending \(samples.count) audio samples")
                    await trusdxAudio.sendAudio(samples, fromSampleRate: 12000)
                    try Task.checkCancellation()
                    Log.d("FT8-TX", "TruSDX: audio sent, going back to RX")
                    try await port.write(";RX;")
                    try? await Task.sleep(nanoseconds: 50_000_000) // 50ms settling
                    Log.d("FT8-TX", "TruSDX: resuming streaming")
                    trusdxAudio.startStreaming()
                    Log.d("FT8-TX", "TruSDX: TX complete")
                } catch is CancellationError {
                    Log.d("FT8-TX", "TruSDX: CANCELLED — sending RX;")
                    try? await port.write(";RX;")
                    trusdxAudio.startStreaming()
                } catch {
                    Log.d("FT8-TX", "TruSDX: ERROR: \(error)")
                    try? await port.write(";RX;")
                    trusdxAudio.startStreaming()
                }
                await MainActor.run {
                    self.isTransmitting = false
                    self.txTask = nil
                    if !Task.isCancelled { self.advanceFT8Sequence() }
                    self.statusText = Task.isCancelled ? "TX abgebrochen" : "Sent"
                }
            }
        } else {
            isTransmitting = true
            txTask = Task {
                if settings.useHamlib {
                    do {
                        try await catController.setMode("USB")
                        try await catController.pttOn()
                        // Allow rig time to switch to TX
                        try await Task.sleep(nanoseconds: 100_000_000) // 100ms
                    } catch {
                        Log.d("FT8-TX", "PTT/Mode error: \(error)")
                    }
                }
                await MainActor.run {
                    self.audioEngine.transmit(samples: samples) { [weak self] in
                        Task { @MainActor in
                            self?.statusText = "Sent"
                            if self?.settings.useHamlib == true { try? await self?.catController.pttOff() }
                            self?.isTransmitting = false
                            self?.txTask = nil
                            self?.advanceFT8Sequence()
                        }
                    }
                }
            }
        }
    }

    // MARK: - JS8 Cycle

    private func startJS8DemodLoop() {
        demodTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64((self?.settings.speed.txWindow ?? 15) * 1_000_000_000))
                await self?.runJS8Demodulation()
            }
        }
    }

    private func runJS8Demodulation() {
        let samples = audioEngine.getBufferedSamples()
        let speed = settings.speed
        guard samples.count > speed.symbolSamples * JS8Protocol.symbolCount else { return }
        Task.detached { [weak self, demodulator = self.js8Demodulator] in
            let results = demodulator.demodulate(samples: samples, speed: speed)
            await MainActor.run {
                for r in results {
                    let p = PackMessage.parseDirected(r.message)
                    let msg = RxMessage(
                        timestamp: Date(), frequency: r.frequency, snr: Int(r.snr),
                        deltaTime: r.deltaTime, text: r.message,
                        mode: .js8, js8Speed: speed, from: p.from, to: p.to
                    )
                    self?.rxMessages.insert(msg, at: 0)
                    if (self?.rxMessages.count ?? 0) > 200 { self?.rxMessages.removeLast() }
                    self?.reportSpot(msg)
                    if let call = p.from { self?.updateStation(callsign: call, frequency: r.frequency, snr: Int(r.snr)) }
                }
            }
        }
        audioEngine.clearBuffer()
    }

    func transmitJS8() {
        guard !txMessage.text.isEmpty, !settings.callsign.isEmpty else {
            statusText = settings.callsign.isEmpty ? "Callsign required!" : ""; return
        }
        statusText = "Sending..."
        let msg = "\(settings.callsign): \(txMessage.text)"
        let samples = js8Modulator.modulate(message: msg, frequency: txMessage.frequency, speed: settings.speed)

        if isTruSDX, let port = trusdxPort {
            // TruSDX: send audio over serial (CAT streaming)
            isTransmitting = true
            // Monitor: play JS8 tone on speaker for debugging (non-critical)
            Log.d("JS8-TX", "Playing monitor audio on speaker (\(samples.count) samples @ 12kHz)")
            audioEngine.transmit(samples: samples, completion: nil)
            txTask = Task {
                do {
                    Log.d("JS8-TX", "TruSDX: setting USB mode (MD2;)")
                    try await port.write("MD2;")
                    Log.d("JS8-TX", "TruSDX: keying TX (TX0;)")
                    try await port.write(";TX0;")
                    try await Task.sleep(nanoseconds: 50_000_000)
                    Log.d("JS8-TX", "TruSDX: sending \(samples.count) audio samples")
                    await trusdxAudio.sendAudio(samples, fromSampleRate: 12000)
                    try Task.checkCancellation()
                    Log.d("JS8-TX", "TruSDX: audio sent, going back to RX")
                    try await port.write(";RX;")
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    Log.d("JS8-TX", "TruSDX: resuming streaming")
                    trusdxAudio.startStreaming()
                    Log.d("JS8-TX", "TruSDX: TX complete")
                } catch is CancellationError {
                    Log.d("JS8-TX", "TruSDX: CANCELLED — sending RX;")
                    try? await port.write(";RX;")
                    trusdxAudio.startStreaming()
                } catch {
                    Log.d("JS8-TX", "TruSDX: ERROR: \(error)")
                    try? await port.write(";RX;")
                    trusdxAudio.startStreaming()
                }
                await MainActor.run {
                    self.isTransmitting = false
                    self.txTask = nil
                    self.statusText = Task.isCancelled ? "TX abgebrochen" : "Sent"
                }
            }
        } else {
            if settings.useHamlib { Task { try? await catController.pttOn() } }
            audioEngine.transmit(samples: samples) { [weak self] in
                Task { @MainActor in
                    self?.statusText = "Sent"
                    if self?.settings.useHamlib == true { try? await self?.catController.pttOff() }
                }
            }
        }
    }

    // MARK: - WSPR Cycle (RX + TX)

    private func startWSPRCycle() {
        cycleTask = Task { [weak self] in
            while !Task.isCancelled {
                // WSPR uses 2-minute windows aligned to even minutes
                let now = Date()
                let calendar = Calendar.current
                let minute = calendar.component(.minute, from: now)
                let second = calendar.component(.second, from: now)
                let nano = calendar.component(.nanosecond, from: now)

                let secondInWindow = Double(second) + Double(nano) / 1_000_000_000
                let isEvenMinute = minute % 2 == 0
                let waitTime: Double
                if isEvenMinute {
                    // Wait until end of current 2-minute window + 0.5s margin
                    waitTime = 120.0 - Double(second) - Double(nano) / 1_000_000_000 + 0.5
                } else {
                    // Wait until next even minute
                    waitTime = 60.0 - secondInWindow + 0.5
                }
                try? await Task.sleep(nanoseconds: UInt64(max(1.0, waitTime) * 1_000_000_000))

                // Run WSPR demodulation on collected audio
                await self?.runWSPRDemodulation()

                // TX if enabled (WSPR TX happens at even minute boundaries)
                if self?.wsprTxEnabled == true {
                    await self?.transmitWSPR()
                }
            }
        }
    }

    private func runWSPRDemodulation() {
        let neededSamples = WSPRProtocol.frameSamples  // ~1.3M samples for 110.6s
        let samples = audioEngine.getBufferedSamples()
        guard samples.count >= neededSamples / 2 else {
            Log.d("WSPR-RX", "Insufficient audio: \(samples.count) samples (need ~\(neededSamples))")
            return
        }
        Log.d("WSPR-RX", "Demodulating \(samples.count) samples")
        Task.detached { [weak self, demodulator = self.wsprDemodulator] in
            let results = demodulator.demodulate(samples)
            await MainActor.run {
                for r in results {
                    let text = "\(r.message.callsign) \(r.message.grid) \(r.message.power)dBm"
                    let msg = RxMessage(
                        timestamp: Date(), frequency: r.frequency, snr: Int(r.snr),
                        deltaTime: r.deltaTime, text: text,
                        mode: .wspr,
                        wsprMessage: r.message
                    )
                    self?.rxMessages.insert(msg, at: 0)
                    if (self?.rxMessages.count ?? 0) > 200 { self?.rxMessages.removeLast() }
                    self?.reportSpot(msg)
                    Log.d("WSPR-RX", "Decoded: \(text) SNR=\(r.snr)dB f=\(String(format: "%.1f", r.frequency))Hz")
                }
                if results.isEmpty {
                    Log.d("WSPR-RX", "No decodes this cycle")
                }
                self?.statusText = results.isEmpty ? "WSPR: kein Decode" : "WSPR: \(results.count) Decode(s)"
            }
        }
    }

    // MARK: - WSPR TX

    func transmitWSPR() {
        guard !settings.callsign.isEmpty, !settings.grid.isEmpty else {
            statusText = settings.callsign.isEmpty ? "Callsign required!" : "Grid required!"
            return
        }
        let msg = WSPRMessage(
            callsign: settings.callsign,
            grid: String(settings.grid.prefix(4)),
            power: wsprPower
        )
        Log.d("WSPR-TX", "transmitWSPR: call='\(msg.callsign)' grid='\(msg.grid)' power=\(msg.power)dBm dialFreq=\(settings.dialFrequency)")
        statusText = "WSPR TX: \(msg.displayText)"
        let samples = wsprModulator.modulate(msg)
        Log.d("WSPR-TX", "Generated \(samples.count) samples (~\(String(format: "%.1f", Double(samples.count)/12000))s)")

        if isTruSDX, let port = trusdxPort {
            isTransmitting = true
            // Monitor: play WSPR tone on speaker for debugging
            Log.d("WSPR-TX", "Playing monitor audio on speaker")
            audioEngine.transmit(samples: samples, completion: nil)
            txTask = Task {
                do {
                    Log.d("WSPR-TX", "TruSDX: setting USB mode (MD2;)")
                    try await port.write("MD2;")
                    Log.d("WSPR-TX", "TruSDX: keying TX (TX0;)")
                    try await port.write(";TX0;")
                    try await Task.sleep(nanoseconds: 50_000_000) // 50ms settling
                    Log.d("WSPR-TX", "TruSDX: sending \(samples.count) audio samples (~110s)")
                    await trusdxAudio.sendAudio(samples, fromSampleRate: 12000)
                    try Task.checkCancellation()
                    Log.d("WSPR-TX", "TruSDX: audio sent, going back to RX")
                    try await port.write(";RX;")
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    Log.d("WSPR-TX", "TruSDX: resuming streaming")
                    trusdxAudio.startStreaming()
                    Log.d("WSPR-TX", "TruSDX: TX complete")
                } catch is CancellationError {
                    Log.d("WSPR-TX", "TruSDX: CANCELLED — sending RX;")
                    try? await port.write(";RX;")
                    trusdxAudio.startStreaming()
                } catch {
                    Log.d("WSPR-TX", "TruSDX: ERROR: \(error)")
                    try? await port.write(";RX;")
                    trusdxAudio.startStreaming()
                }
                await MainActor.run {
                    self.isTransmitting = false
                    self.txTask = nil
                    self.statusText = Task.isCancelled ? "TX abgebrochen" : "WSPR Sent"
                }
            }
        } else {
            if settings.useHamlib { Task { try? await catController.pttOn() } }
            audioEngine.transmit(samples: samples) { [weak self] in
                Task { @MainActor in
                    self?.statusText = "WSPR Sent"
                    if self?.settings.useHamlib == true { try? await self?.catController.pttOff() }
                }
            }
        }
    }

    // MARK: - CW / Morse

    @Published var cwKeying = false

    /// Update GGMorse decoder sample rate if needed
    private func ensureCWDecoderRate(_ sampleRate: Int) {
        let rate = Float(sampleRate)
        guard rate != cwDecoder.sampleRate, sampleRate > 0 else { return }
        cwDecoder.updateSampleRate(rate)
    }

    /// Start continuous CW decoding from audio input (using ggmorse)
    private func startCWDecodeLoop() {
        cwDecoding = true
        let rate = Int(audioEngine.effectiveSampleRate)
        ensureCWDecoderRate(rate)
        cwDecoder.reset()
        Log.d("GGMorse", "*** startCWDecodeLoop STARTED *** sampleRate=\(rate)")
        demodTask = Task { [weak self] in
            var loopCount = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms chunks
                guard let self else { Log.d("GGMorse", "self is nil, exiting"); break }
                // Adapt to sample rate changes
                let currentRate = Int(self.audioEngine.effectiveSampleRate)
                self.ensureCWDecoderRate(currentRate)
                let samples = self.audioEngine.getBufferedSamples()
                loopCount += 1
                if loopCount <= 20 || loopCount % 10 == 0 {
                    let rms = samples.isEmpty ? 0 : sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
                    Log.d("GGMorse", "#\(loopCount): \(samples.count) samples, rms=\(String(format: "%.4f", rms)), pitch=\(self.cwDecoder.pitch)Hz, wpm=\(self.cwDecoder.wpm)")
                }
                guard !samples.isEmpty else { continue }
                let decoded = self.cwDecoder.process(samples: samples)
                if !decoded.isEmpty {
                    Log.d("GGMorse", "*** DECODED: '\(decoded)' *** pitch=\(self.cwDecoder.pitch)Hz wpm=\(self.cwDecoder.wpm)")
                    await MainActor.run {
                        self.cwDecodedText += decoded
                        if self.cwDecodedText.count > 2000 {
                            self.cwDecodedText = String(self.cwDecodedText.suffix(1500))
                        }
                    }
                }
                self.audioEngine.clearBuffer()
            }
            Log.d("GGMorse", "loop exited after \(loopCount) iterations")
        }
    }

    /// Stop CW decoding
    func stopCWDecoding() {
        demodTask?.cancel(); demodTask = nil
        cwDecoding = false
    }

    /// Clear decoded CW text
    func clearCWDecoded() {
        cwDecodedText = ""
        cwDecoder.reset()
    }

    func sendCW() {
        guard !cwText.isEmpty else { statusText = "Kein CW-Text"; return }
        guard radioState.isConnected else { statusText = "Kein Rig verbunden"; return }
        let text = cwText.uppercased()
        let speed = cwSpeed
        statusText = "CW: \(text)"
        cwLog.insert("TX: \(text)", at: 0)
        if cwLog.count > 50 { cwLog.removeLast() }
        cwText = ""
        cwKeying = true
        isTransmitting = true

        if isTruSDX, let port = trusdxPort {
            // TruSDX: direct POSIX writes for zero-latency CW keying
            let fd = port.rawFD
            guard fd >= 0 else { statusText = "Serial port not open"; cwKeying = false; return }

            // Pause read loop during CW TX to avoid contention
            Log.d("CW-TX", "TruSDX: pausing audio streaming for CW")
            trusdxAudio.stopStreaming()

            // Set CW mode synchronously before keying starts
            Log.d("CW-TX", "TruSDX: setting CW mode (MD3;) fd=\(fd)")
            let md3 = Array("MD3;".utf8)
            md3.withUnsafeBufferPointer { _ = Darwin.write(fd, $0.baseAddress!, $0.count) }
            Thread.sleep(forTimeInterval: 0.05) // 50ms for mode switch to take effect

            // Direct POSIX write — no actor, no Task, no await, ~microseconds
            let tx0 = Array("TX0;".utf8)
            let rx  = Array(";RX;".utf8)
            let keyDown: () -> Void = {
                Log.d("CW-TX", "KEY DOWN")
                tx0.withUnsafeBufferPointer { _ = Darwin.write(fd, $0.baseAddress!, $0.count) }
            }
            let keyUp: () -> Void = {
                Log.d("CW-TX", "KEY UP")
                rx.withUnsafeBufferPointer { _ = Darwin.write(fd, $0.baseAddress!, $0.count) }
            }

            Log.d("CW-TX", "TruSDX: starting keyer, \(text) @ \(speed) WPM")
            morseKeyer.key(text: text, wpm: speed, keyDown: keyDown, keyUp: keyUp) { [weak self] in
                Log.d("CW-TX", "TruSDX: keying complete, resuming streaming")
                self?.trusdxAudio.startStreaming()
                self?.cwKeying = false
                self?.isTransmitting = false
                self?.statusText = "CW gesendet"
            }
        } else {
            // Other rigs (FT-817 etc.): Audio CW tone via USB mode.
            // Stay in USB — do NOT switch to CW mode. The rig treats the
            // keyed sine wave as a normal audio signal, just like FT8.
            Log.d("CW-TX", "Audio-CW: generating tone, \(text) @ \(speed) WPM")
            let samples = CWToneGenerator.generate(text: text, wpm: speed)
            guard !samples.isEmpty else {
                cwKeying = false
                isTransmitting = false
                statusText = "CW: leerer Text"
                return
            }
            Log.d("CW-TX", "Audio-CW: \(samples.count) samples (\(String(format: "%.1f", Double(samples.count) / 12000.0))s)")

            Task {
                do { try await catController.pttOn() }
                catch { Log.d("CW-TX", "PTT on error: \(error)") }

                // Small delay for rig TX switch
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms

                await MainActor.run {
                    self.audioEngine.transmit(samples: samples) { [weak self] in
                        Task {
                            do { try await self?.catController.pttOff() }
                            catch { Log.d("CW-TX", "PTT off error: \(error)") }
                        }
                        self?.cwKeying = false
                        self?.isTransmitting = false
                        self?.statusText = "CW gesendet"
                    }
                }
            }
        }
    }

    func stopCW() {
        morseKeyer.stop()
        if isTruSDX, let port = trusdxPort {
            // Direct POSIX write for immediate stop
            let fd = port.rawFD
            if fd >= 0 {
                Log.d("CW-TX", "TruSDX: STOP — sending RX;")
                let rx = Array(";RX;".utf8)
                rx.withUnsafeBufferPointer { _ = Darwin.write(fd, $0.baseAddress!, $0.count) }
            }
            // Resume streaming
            Log.d("CW-TX", "TruSDX: resuming streaming after stop")
            trusdxAudio.startStreaming()
        } else {
            // Stop audio playback and PTT
            audioEngine.stopPlayback()
            Task { try? await catController.pttOff() }
        }
        cwKeying = false
        isTransmitting = false
        statusText = "CW gestoppt"
    }

    // MARK: - Spot Reporters

    /// Initialize or tear down spot reporters based on settings.
    func setupSpotReporters() {
        let call = settings.callsign
        let grid = settings.grid
        guard !call.isEmpty else {
            stopAllReporters()
            return
        }

        // PSK Reporter
        if settings.pskReporterEnabled {
            if pskReporter == nil {
                pskReporter = PSKReporter(callsign: call, grid: grid, antenna: settings.antenna)
                pskReporter?.start()
                Log.d("Reporters", "PSK Reporter enabled")
            }
        } else if pskReporter != nil {
            pskReporter?.stop()
            pskReporter = nil
            Log.d("Reporters", "PSK Reporter disabled")
        }

        // RBN Reporter
        if settings.rbnReporterEnabled {
            if rbnReporter == nil {
                rbnReporter = RBNReporter(callsign: call, grid: grid)
                rbnReporter?.start()
                Log.d("Reporters", "RBN Reporter enabled")
            }
        } else if rbnReporter != nil {
            rbnReporter?.stop()
            rbnReporter = nil
            Log.d("Reporters", "RBN Reporter disabled")
        }

        // WSPRNet Reporter
        if settings.wsprNetReporterEnabled {
            if wsprNetReporter == nil {
                wsprNetReporter = WSPRNetReporter(callsign: call, grid: grid)
                wsprNetReporter?.start()
                Log.d("Reporters", "WSPRNet Reporter enabled")
            }
        } else if wsprNetReporter != nil {
            wsprNetReporter?.stop()
            wsprNetReporter = nil
            Log.d("Reporters", "WSPRNet Reporter disabled")
        }
    }

    private func stopAllReporters() {
        pskReporter?.stop(); pskReporter = nil
        rbnReporter?.stop(); rbnReporter = nil
        wsprNetReporter?.stop(); wsprNetReporter = nil
    }

    /// Report a decoded RX message to all active reporters.
    private func reportSpot(_ msg: RxMessage) {
        let call = settings.callsign
        guard !call.isEmpty else { return }

        // Extract spotted callsign from the decoded message
        var spottedCall: String?
        switch msg.mode {
        case .ft8:
            spottedCall = msg.ft8Message?.from
        case .js8:
            spottedCall = msg.from
        case .wspr:
            spottedCall = msg.wsprMessage?.callsign
        default:
            break
        }
        guard let spottedCall, !spottedCall.isEmpty else { return }

        let dialFreq = settings.dialFrequency
        let spotFreqHz = Int(dialFreq + msg.frequency)

        let spot = Spot(
            timestamp: msg.timestamp,
            frequency: spotFreqHz,
            callsign: spottedCall,
            snr: msg.snr,
            mode: msg.mode.name,
            spotterCallsign: call
        )

        // PSK Reporter and RBN accept all digital mode spots
        pskReporter?.report(spot)
        rbnReporter?.report(spot)

        // WSPRNet gets WSPR-specific reports with extra metadata
        if msg.mode == .wspr, let wspr = msg.wsprMessage {
            let formatter = DateFormatter()
            formatter.dateFormat = "HHmm"
            formatter.timeZone = TimeZone(identifier: "UTC")
            wsprNetReporter?.reportWSPR(
                txCallsign: wspr.callsign,
                txGrid: wspr.grid,
                powerDBm: wspr.power,
                snr: msg.snr,
                dt: msg.deltaTime,
                drift: 0,
                txFreqHz: spotFreqHz,
                dialFreqHz: Int(dialFreq),
                timestamp: formatter.string(from: msg.timestamp)
            )
        }
    }

    // MARK: - Helpers

    private func updateStation(callsign: String, grid: String = "", frequency: Double, snr: Int) {
        if let i = stations.firstIndex(where: { $0.callsign == callsign }) {
            stations[i].frequency = frequency; stations[i].snr = snr; stations[i].lastHeard = Date()
            if !grid.isEmpty { stations[i].grid = grid }
        } else {
            stations.append(Station(callsign: callsign, grid: grid, frequency: frequency, snr: snr))
        }
    }

    private func addWaterfallRow(_ spectrum: [Float]) {
        waterfallData.append(spectrum)
        if waterfallData.count > 200 { waterfallData.removeFirst(waterfallData.count - 200) }
    }
}
