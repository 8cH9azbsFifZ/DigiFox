import Foundation
import Combine

enum DigitalMode: Int, CaseIterable, Identifiable {
    case ft8 = 0
    case js8 = 1
    case cw = 4
    var id: Int { rawValue }
    var name: String {
        switch self {
        case .ft8: return "FT8"
        case .js8: return "JS8Call"
        case .cw:  return "CW"
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
    private var cancellables = Set<AnyCancellable>()
    private var demodTask: Task<Void, Never>?
    private var usbScanTask: Task<Void, Never>?
    private var cycleTask: Task<Void, Never>?
    private var rigPollTask: Task<Void, Never>?

    init() {
        // Pre-fill DX call/grid from settings
        dxCall = settings.callsign
        dxGrid = settings.grid
        // Initial CW decoder (ggmorse) at default rate
        cwDecoder = GGMorseDecoder(sampleRate: 12000)
        setupBindings()
        #if targetEnvironment(simulator)
        ioKitAvailable = true
        #else
        ioKitAvailable = SerialPort.isAvailable
        #endif
        startUSBMonitoring()
        updateTxMessages()
        startReceiving()
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

    // MARK: - Rig Control

    func connectRig() {
        guard settings.useHamlib else { statusText = "No rig model selected"; return }
        let baudRate = settings.radioProfile.defaultBaudRate
        let modelId = settings.radioProfile == .trusdx ? settings.radioProfile.defaultHamlibModel : settings.rigModel
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
                    print("[Connect] TruSDX: opening port \(dev.path) @ \(baudRate)")
                    let port = SerialPort()
                    try await port.open(path: dev.path, baudRate: UInt(baudRate))
                    trusdxPort = port
                    trusdxAudio.attach(to: port)
                    print("[Connect] TruSDX: port opened, rawFD=\(port.rawFD)")

                    // Send initial CAT commands directly
                    try await port.write("ID;")   // verify connection
                    let rigMode = settings.digitalMode == .cw ? "MD3;" : "MD2;"
                    print("[Connect] TruSDX: sending \(rigMode)")
                    try await port.write(rigMode)
                    if let freq = BandPlan.dialFrequency(band: settings.selectedBand, mode: settings.digitalMode) {
                        let freqCmd = String(format: "FA%011d;", Int(freq))
                        print("[Connect] TruSDX: sending \(freqCmd)")
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
                    print("[Connect] TruSDX: starting audio streaming")
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
            } catch { statusText = "Rig error: \(error.localizedDescription)" }
        }
    }

    func disconnectRig() {
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
                    print("[Mode] TruSDX: stop streaming → \(modeCmd) → restart streaming")
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
            }
            print("[Mode] \(mode): freq/mode set, decode loop started")
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
                    await MainActor.run { self.radioState.isConnected = false; self.statusText = "Rig connection lost" }
                    break
                }
            }
        }
    }

    func setRigFrequency(_ hz: UInt64) {
        if isTruSDX, let port = trusdxPort {
            let cmd = String(format: "FA%011d;", hz)
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
        for d in usbDevices.filter({ d in !prev.contains(where: { $0.path == d.path }) }) {
            statusText = d.isDigirig ? "🔌 Digirig detected: \(d.path)" : "🔌 USB device: \(d.name)"
        }
    }

    var digirigConnected: Bool { usbDevices.contains { $0.isDigirig } }
    var trusdxConnected: Bool { usbDevices.contains { $0.isTruSDX } }
    var isTruSDX: Bool { settings.radioProfile == .trusdx }
    var hasCompatibleDevice: Bool {
        switch settings.radioProfile {
        case .trusdx: return trusdxConnected || !usbDevices.isEmpty
        case .digirig: return digirigConnected || !usbDevices.isEmpty
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
        if settings.useHamlib && !radioState.isConnected && hasCompatibleDevice { connectRig() }
        if !isTruSDX {
            audioEngine.start()
        }
        switch settings.digitalMode {
        case .ft8: startFT8Cycle()
        case .js8: startJS8DemodLoop()
        case .cw:  startCWDecodeLoop()
        }
        isReceiving = true
        statusText = radioState.isConnected ? "Receiving (rig connected)" : "Receiving..."
    }

    func stopReceiving() {
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
                if self?.txEnabled == true && isEvenSlot == self?.txEven { await self?.transmitFT8() }
            }
        }
    }

    private func runFT8Demodulation() {
        let samples = audioEngine.getBufferedSamples()
        guard samples.count > FT8Protocol.symbolSamples * FT8Protocol.symbolCount else { return }
        Task.detached { [weak self, demodulator = self.ft8Demodulator] in
            let results = demodulator.demodulate(samples)
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
        guard selectedTxMessage < txMessages.count else { return }
        let msgText = txMessages[selectedTxMessage]
        guard !msgText.isEmpty else { return }
        statusText = "Sending: \(msgText)"
        let ft8Msg = FT8MessagePack.parseText(msgText, myCall: settings.callsign, myGrid: settings.grid)
        ft8Modulator.baseFrequency = txFrequency
        let samples = ft8Modulator.modulate(ft8Msg)

        if isTruSDX, let port = trusdxPort {
            // TruSDX: send audio over serial (CAT streaming)
            isTransmitting = true
            Task {
                do {
                    print("[FT8-TX] TruSDX: setting USB mode (MD2;)")
                    try await port.write("MD2;")
                    print("[FT8-TX] TruSDX: keying TX (TX0;)")
                    try await port.write("TX0;")
                    print("[FT8-TX] TruSDX: sending \(samples.count) audio samples")
                    await trusdxAudio.sendAudio(samples, fromSampleRate: 12000)
                    print("[FT8-TX] TruSDX: audio sent, going back to RX")
                    try await port.write("RX;")
                    print("[FT8-TX] TruSDX: TX complete")
                } catch {
                    print("[FT8-TX] TruSDX: ERROR: \(error)")
                }
                await MainActor.run {
                    self.isTransmitting = false
                    self.statusText = "Sent"
                    self.advanceFT8Sequence()
                }
            }
        } else {
            if settings.useHamlib { Task { try? await catController.setMode("USB"); try? await catController.pttOn() } }
            audioEngine.transmit(samples: samples) { [weak self] in
                Task { @MainActor in
                    self?.statusText = "Sent"
                    if self?.settings.useHamlib == true { try? await self?.catController.pttOff() }
                    self?.advanceFT8Sequence()
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
            Task {
                do {
                    print("[JS8-TX] TruSDX: setting USB mode (MD2;)")
                    try await port.write("MD2;")
                    print("[JS8-TX] TruSDX: keying TX (TX0;)")
                    try await port.write("TX0;")
                    print("[JS8-TX] TruSDX: sending \(samples.count) audio samples")
                    await trusdxAudio.sendAudio(samples, fromSampleRate: 12000)
                    print("[JS8-TX] TruSDX: audio sent, going back to RX")
                    try await port.write("RX;")
                    print("[JS8-TX] TruSDX: TX complete")
                } catch {
                    print("[JS8-TX] TruSDX: ERROR: \(error)")
                }
                await MainActor.run {
                    self.isTransmitting = false
                    self.statusText = "Sent"
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
        print("[GGMorse] *** startCWDecodeLoop STARTED *** sampleRate=\(rate)")
        demodTask = Task { [weak self] in
            var loopCount = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms chunks
                guard let self else { print("[GGMorse] self is nil, exiting"); break }
                // Adapt to sample rate changes
                let currentRate = Int(self.audioEngine.effectiveSampleRate)
                self.ensureCWDecoderRate(currentRate)
                let samples = self.audioEngine.getBufferedSamples()
                loopCount += 1
                if loopCount <= 20 || loopCount % 10 == 0 {
                    let rms = samples.isEmpty ? 0 : sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
                    print("[GGMorse] #\(loopCount): \(samples.count) samples, rms=\(String(format: "%.4f", rms)), pitch=\(self.cwDecoder.pitch)Hz, wpm=\(self.cwDecoder.wpm)")
                }
                guard !samples.isEmpty else { continue }
                let decoded = self.cwDecoder.process(samples: samples)
                if !decoded.isEmpty {
                    print("[GGMorse] *** DECODED: '\(decoded)' *** pitch=\(self.cwDecoder.pitch)Hz wpm=\(self.cwDecoder.wpm)")
                    await MainActor.run {
                        self.cwDecodedText += decoded
                        if self.cwDecodedText.count > 2000 {
                            self.cwDecodedText = String(self.cwDecodedText.suffix(1500))
                        }
                    }
                }
                self.audioEngine.clearBuffer()
            }
            print("[GGMorse] loop exited after \(loopCount) iterations")
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

        if isTruSDX, let port = trusdxPort {
            // TruSDX: direct POSIX writes for zero-latency CW keying
            let fd = port.rawFD
            guard fd >= 0 else { statusText = "Serial port not open"; cwKeying = false; return }

            // Pause read loop during CW TX to avoid contention
            print("[CW-TX] TruSDX: pausing audio streaming for CW")
            trusdxAudio.stopStreaming()

            // Set CW mode synchronously before keying starts
            print("[CW-TX] TruSDX: setting CW mode (MD3;) fd=\(fd)")
            let md3 = Array("MD3;".utf8)
            md3.withUnsafeBufferPointer { _ = Darwin.write(fd, $0.baseAddress!, $0.count) }
            Thread.sleep(forTimeInterval: 0.05) // 50ms for mode switch to take effect

            // Direct POSIX write — no actor, no Task, no await, ~microseconds
            let tx0 = Array("TX0;".utf8)
            let rx  = Array("RX;".utf8)
            let keyDown: () -> Void = {
                print("[CW-TX] KEY DOWN")
                tx0.withUnsafeBufferPointer { _ = Darwin.write(fd, $0.baseAddress!, $0.count) }
            }
            let keyUp: () -> Void = {
                print("[CW-TX] KEY UP")
                rx.withUnsafeBufferPointer { _ = Darwin.write(fd, $0.baseAddress!, $0.count) }
            }

            print("[CW-TX] TruSDX: starting keyer, \(text) @ \(speed) WPM")
            morseKeyer.key(text: text, wpm: speed, keyDown: keyDown, keyUp: keyUp) { [weak self] in
                print("[CW-TX] TruSDX: keying complete, resuming streaming")
                self?.trusdxAudio.startStreaming()
                self?.cwKeying = false
                self?.statusText = "CW gesendet"
            }
        } else {
            // Other rigs: via Hamlib/CATController
            Task {
                try? await catController.setMode("CW")
                let rig = await catController.getHamlibRig()
                let ioQueue = DispatchQueue(label: "morse.ptt", qos: .userInteractive)
                let keyDown = { ioQueue.async { try? rig?.setPTT(true) } }
                let keyUp   = { ioQueue.async { try? rig?.setPTT(false) } }

                await MainActor.run {
                    self.morseKeyer.key(text: text, wpm: speed, keyDown: keyDown, keyUp: keyUp) { [weak self] in
                        self?.cwKeying = false
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
                print("[CW-TX] TruSDX: STOP — sending RX;")
                let rx = Array("RX;".utf8)
                rx.withUnsafeBufferPointer { _ = Darwin.write(fd, $0.baseAddress!, $0.count) }
            }
            // Resume streaming
            print("[CW-TX] TruSDX: resuming streaming after stop")
            trusdxAudio.startStreaming()
        } else {
            Task { try? await catController.pttOff() }
        }
        cwKeying = false
        statusText = "CW gestoppt"
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
