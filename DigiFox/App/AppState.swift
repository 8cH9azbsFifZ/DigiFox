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
    private let cwDecoder = CWDecoder()

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
        audioEngine.$isRunning.assign(to: &$isReceiving)
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
                try await catController.connect(modelId: modelId, path: dev.path, baudRate: baudRate)

                // FT8 and JS8Call require USB mode
                try await catController.setMode("USB")

                // Set dial frequency for current band/mode
                if let freq = BandPlan.dialFrequency(band: settings.selectedBand, mode: settings.digitalMode) {
                    try await catController.setFrequency(UInt64(freq))
                }

                radioState = await catController.state
                let displayName = settings.radioProfile == .trusdx ? "(tr)uSDX" : radioState.rigName
                statusText = "Connected: \(displayName) (USB)"
                startRigPolling()
            } catch { statusText = "Rig error: \(error.localizedDescription)" }
        }
    }

    func disconnectRig() {
        rigPollTask?.cancel(); rigPollTask = nil
        Task { await catController.disconnect(); radioState = await catController.state; statusText = "Rig disconnected" }
    }

    /// Switch digital mode: update dial frequency and send to rig if connected
    func switchMode(_ mode: DigitalMode) {
        guard settings.digitalMode != mode else { return }
        settings.digitalMode = mode
        if radioState.isConnected {
            if let freq = BandPlan.dialFrequency(band: settings.selectedBand, mode: mode) {
                setRigFrequency(UInt64(freq))
            }
            let rigMode = mode == .cw ? "CW" : "USB"
            Task { try? await catController.setMode(rigMode) }
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
        Task {
            do {
                try await catController.setFrequency(hz)
                settings.dialFrequency = Double(hz)
                radioState.frequency = hz
            }
            catch { statusText = "Frequency error: \(error.localizedDescription)" }
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
        audioEngine.start()
        switch settings.digitalMode {
        case .ft8: startFT8Cycle()
        case .js8: startJS8DemodLoop()
        case .cw:  startCWDecodeLoop()
        }
        isReceiving = true
        statusText = radioState.isConnected ? "Receiving (rig connected)" : "Receiving..."
    }

    func stopReceiving() {
        audioEngine.stop()
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
        if settings.useHamlib { Task { try? await catController.pttOn() } }
        let ft8Msg = FT8MessagePack.parseText(msgText, myCall: settings.callsign, myGrid: settings.grid)
        ft8Modulator.baseFrequency = txFrequency
        let samples = ft8Modulator.modulate(ft8Msg)
        audioEngine.transmit(samples: samples) { [weak self] in
            Task { @MainActor in
                self?.statusText = "Sent"
                if self?.settings.useHamlib == true { try? await self?.catController.pttOff() }
                self?.advanceFT8Sequence()
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
        if settings.useHamlib { Task { try? await catController.pttOn() } }
        let msg = "\(settings.callsign): \(txMessage.text)"
        let samples = js8Modulator.modulate(message: msg, frequency: txMessage.frequency, speed: settings.speed)
        audioEngine.transmit(samples: samples) { [weak self] in
            Task { @MainActor in
                self?.statusText = "Sent"
                if self?.settings.useHamlib == true { try? await self?.catController.pttOff() }
            }
        }
    }

    // MARK: - CW / Morse

    @Published var cwKeying = false

    /// Start continuous CW decoding from audio input
    private func startCWDecodeLoop() {
        cwDecoding = true
        cwDecoder.reset()
        demodTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms chunks
                guard let self else { break }
                let samples = self.audioEngine.getBufferedSamples()
                guard !samples.isEmpty else { continue }
                let decoded = self.cwDecoder.process(samples: samples)
                if !decoded.isEmpty {
                    await MainActor.run {
                        self.cwDecodedText += decoded
                        // Keep last 2000 chars
                        if self.cwDecodedText.count > 2000 {
                            self.cwDecodedText = String(self.cwDecodedText.suffix(1500))
                        }
                    }
                }
                self.audioEngine.clearBuffer()
            }
        }
    }

    /// Stop CW decoding and flush remaining text
    func stopCWDecoding() {
        demodTask?.cancel(); demodTask = nil
        let remaining = cwDecoder.finalize()
        if !remaining.isEmpty { cwDecodedText += remaining }
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

        // Set CW mode before keying
        Task { try? await catController.setMode("CW") }

        // Synchronous PTT callbacks for the keying thread
        let cat = catController
        let keyDown = { let s = DispatchSemaphore(value: 0); Task { try? await cat.pttOn(); s.signal() }; s.wait() }
        let keyUp   = { let s = DispatchSemaphore(value: 0); Task { try? await cat.pttOff(); s.signal() }; s.wait() }

        morseKeyer.key(text: text, wpm: speed, keyDown: keyDown, keyUp: keyUp) { [weak self] in
            self?.cwKeying = false
            self?.statusText = "CW gesendet"
        }
    }

    func stopCW() {
        morseKeyer.stop()
        Task { try? await catController.pttOff() }
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
