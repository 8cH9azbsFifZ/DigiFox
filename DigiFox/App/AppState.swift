import Foundation
import Combine

enum DigitalMode: Int, CaseIterable, Identifiable {
    case ft8 = 0
    case js8 = 1
    var id: Int { rawValue }
    var name: String { self == .ft8 ? "FT8" : "JS8Call" }
}

@MainActor
class AppState: ObservableObject {
    // MARK: - Shared State
    @Published var rxMessages = [RxMessage]()
    @Published var stations = [Station]()
    @Published var waterfallData = [[Float]]()
    @Published var isReceiving = false
    @Published var isTransmitting = false
    @Published var statusText = "Bereit"
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
    @Published var js8Mode: JS8AppMode = .standalone
    enum JS8AppMode: String, CaseIterable { case standalone = "Standalone", network = "Netzwerk" }

    let settings = AppSettings()
    let audioEngine = AudioEngine()
    let networkClient = JS8NetworkClient()
    let catController = CATController()

    private let ft8Modulator = FT8Modulator()
    private let ft8Demodulator = FT8Demodulator()
    private let js8Modulator = JS8Modulator()
    private let js8Demodulator = JS8Demodulator()
    private var cancellables = Set<AnyCancellable>()
    private var demodTask: Task<Void, Never>?
    private var usbScanTask: Task<Void, Never>?
    private var cycleTask: Task<Void, Never>?

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
        networkClient.onMessageReceived = { [weak self] msg in
            Task { @MainActor in self?.handleNetworkMessage(msg) }
        }
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
        statusText = "QSO geloggt: \(dxCall)"
    }

    private func advanceFT8Sequence() {
        guard autoSequence else { return }
        if selectedTxMessage < 4 { selectedTxMessage += 1; updateTxMessages() }
        else { txEnabled = false; statusText = "QSO abgeschlossen" }
    }

    // MARK: - Rig Control

    func connectRig() {
        guard settings.useHamlib else { statusText = "Kein Rig-Modell ausgewählt"; return }
        Task {
            do {
                if let digirig = SerialPort.findDigirig() {
                    try await catController.connect(modelId: settings.rigModel, path: digirig.path, baudRate: settings.rigSerialRate)
                } else {
                    let devices = SerialPort.discoverDevices()
                    guard let first = devices.first else { statusText = "Kein USB-Serial-Gerät gefunden"; return }
                    try await catController.connect(modelId: settings.rigModel, path: first.path, baudRate: settings.rigSerialRate)
                }
                radioState = await catController.state
                statusText = "Verbunden: \(radioState.rigName)"
            } catch { statusText = "Rig-Fehler: \(error.localizedDescription)" }
        }
    }

    func disconnectRig() {
        Task { await catController.disconnect(); radioState = await catController.state; statusText = "Rig getrennt" }
    }

    func setRigFrequency(_ hz: UInt64) {
        Task {
            do { try await catController.setFrequency(hz); radioState = await catController.state }
            catch { statusText = "Frequenz-Fehler: \(error.localizedDescription)" }
        }
    }

    // MARK: - USB Monitoring

    func scanUSBDevices() {
        let prev = usbDevices
        usbDevices = SerialPort.discoverDevices()
        for d in usbDevices.filter({ d in !prev.contains(where: { $0.path == d.path }) }) {
            statusText = d.isDigirig ? "🔌 Digirig erkannt: \(d.path)" : "🔌 USB-Gerät: \(d.name)"
        }
    }

    var digirigConnected: Bool { usbDevices.contains { $0.isDigirig } }

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
        if settings.useHamlib && !radioState.isConnected && digirigConnected { connectRig() }
        audioEngine.start()
        if settings.digitalMode == .ft8 { startFT8Cycle() } else { startJS8DemodLoop() }
        isReceiving = true
        statusText = radioState.isConnected ? "Empfange (Rig verbunden)" : "Empfange..."
    }

    func stopReceiving() {
        audioEngine.stop()
        demodTask?.cancel(); demodTask = nil
        cycleTask?.cancel(); cycleTask = nil
        if radioState.isConnected { disconnectRig() }
        isReceiving = false; txEnabled = false
        statusText = "Gestoppt"
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
        statusText = "Sende: \(msgText)"
        if settings.useHamlib { Task { try? await catController.pttOn() } }
        let ft8Msg = FT8MessagePack.parseText(msgText, myCall: settings.callsign, myGrid: settings.grid)
        ft8Modulator.baseFrequency = txFrequency
        let samples = ft8Modulator.modulate(ft8Msg)
        audioEngine.transmit(samples: samples) { [weak self] in
            Task { @MainActor in
                self?.statusText = "Gesendet"
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
            statusText = settings.callsign.isEmpty ? "Rufzeichen fehlt!" : ""; return
        }
        statusText = "Sende..."
        if settings.useHamlib { Task { try? await catController.pttOn() } }
        let msg = "\(settings.callsign): \(txMessage.text)"
        let samples = js8Modulator.modulate(message: msg, frequency: txMessage.frequency, speed: settings.speed)
        audioEngine.transmit(samples: samples) { [weak self] in
            Task { @MainActor in
                self?.statusText = "Gesendet"
                if self?.settings.useHamlib == true { try? await self?.catController.pttOff() }
            }
        }
    }

    // MARK: - JS8 Network

    func connectNetwork() { networkClient.connect(host: settings.networkHost, port: settings.networkPort); statusText = "Verbinde..." }
    func disconnectNetwork() { networkClient.disconnect(); statusText = "Getrennt" }
    func sendNetworkMessage() {
        guard !txMessage.text.isEmpty else { return }
        networkClient.sendText(txMessage.text); statusText = "Gesendet (Netzwerk)"
    }

    private func handleNetworkMessage(_ msg: JS8APIMessage) {
        switch msg.type {
        case "RX.DIRECTED", "RX.ACTIVITY":
            let rx = RxMessage(
                timestamp: Date(), frequency: Double(msg.params?["FREQ"] ?? "0") ?? 0,
                snr: Int(msg.params?["SNR"] ?? "0") ?? 0, deltaTime: 0, text: msg.value,
                mode: .js8, js8Speed: settings.speed, from: msg.params?["FROM"], to: msg.params?["TO"]
            )
            rxMessages.insert(rx, at: 0)
        case "STATION.STATUS": statusText = "Verbunden: \(msg.value)"
        default: break
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
