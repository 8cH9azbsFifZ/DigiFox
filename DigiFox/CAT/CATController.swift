import Foundation

/// Protocol-agnostic CAT (Computer Aided Transceiver) controller.
/// Manages sending commands and parsing responses over a serial connection.
class CATController: ObservableObject {
    
    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected
        case error(String)
    }
    
    @Published var connectionState: ConnectionState = .disconnected
    @Published var frequency: UInt64 = 0
    @Published var mode: RadioMode = .unknown
    @Published var isTransmitting: Bool = false
    
    private let serialPort: USBSerialPort
    private var responseBuffer = ""
    private var pendingCallbacks: [(String) -> Void] = []
    private var pollingTimer: Timer?
    
    init(serialPort: USBSerialPort = USBSerialPort()) {
        self.serialPort = serialPort
        self.serialPort.onDataReceived = { [weak self] data in
            self?.handleReceivedData(data)
        }
    }
    
    deinit {
        disconnect()
    }
    
    /// Connect to the radio at the given serial port path
    func connect(portPath: String, baudRate: speed_t = 38400) {
        connectionState = .connecting
        
        do {
            try serialPort.connect(path: portPath, baudRate: baudRate)
            connectionState = .connected
            startPolling()
        } catch {
            connectionState = .error(error.localizedDescription)
        }
    }
    
    /// Auto-detect and connect to a TruSDX
    func autoConnect() {
        connectionState = .connecting
        
        let ports = USBSerialPort.availablePorts()
        guard let port = ports.first else {
            connectionState = .error("No USB serial device found. Connect your (tr)uSDX via USB-C.")
            return
        }
        
        connect(portPath: port)
    }
    
    /// Disconnect from the radio
    func disconnect() {
        pollingTimer?.invalidate()
        pollingTimer = nil
        serialPort.disconnect()
        connectionState = .disconnected
    }
    
    /// Send a raw CAT command
    func sendCommand(_ command: String) {
        guard serialPort.isConnected else { return }
        try? serialPort.write(command)
    }
    
    // MARK: - TruSDX Kenwood TS-480 CAT Commands
    
    /// Set VFO A frequency in Hz
    func setFrequency(_ hz: UInt64) {
        let cmd = String(format: "FA%011d;", hz)
        sendCommand(cmd)
        frequency = hz
    }
    
    /// Query current frequency
    func queryFrequency() {
        sendCommand("FA;")
    }
    
    /// Set operating mode
    func setMode(_ mode: RadioMode) {
        sendCommand("MD\(mode.catValue);")
        self.mode = mode
    }
    
    /// Query current mode
    func queryMode() {
        sendCommand("MD;")
    }
    
    /// Key transmitter (PTT on)
    func transmit() {
        sendCommand("TX;")
        isTransmitting = true
    }
    
    /// Unkey transmitter (PTT off)
    func receive() {
        sendCommand("RX;")
        isTransmitting = false
    }
    
    /// Query transceiver info
    func queryInfo() {
        sendCommand("IF;")
    }
    
    // MARK: - Private
    
    private func startPolling() {
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.queryFrequency()
            self?.queryMode()
        }
    }
    
    private func handleReceivedData(_ data: Data) {
        guard let text = String(data: data, encoding: .ascii) else { return }
        responseBuffer += text
        
        // Parse complete responses (terminated by ';')
        while let semicolonIndex = responseBuffer.firstIndex(of: ";") {
            let response = String(responseBuffer[responseBuffer.startIndex...semicolonIndex])
            responseBuffer = String(responseBuffer[responseBuffer.index(after: semicolonIndex)...])
            parseResponse(response)
        }
    }
    
    private func parseResponse(_ response: String) {
        guard response.count >= 2 else { return }
        
        let prefix = String(response.prefix(2))
        let payload = String(response.dropFirst(2).dropLast()) // Remove prefix and trailing ';'
        
        switch prefix {
        case "FA":
            if let freq = UInt64(payload) {
                DispatchQueue.main.async { self.frequency = freq }
            }
        case "MD":
            if let modeValue = Int(payload), let radioMode = RadioMode(catValue: modeValue) {
                DispatchQueue.main.async { self.mode = radioMode }
            }
        case "IF":
            parseInfoResponse(payload)
        default:
            break
        }
    }
    
    private func parseInfoResponse(_ payload: String) {
        // IF response format: IF[freq 11][step][rit/xit][rit offset][...][mode][...]
        guard payload.count >= 28 else { return }
        let chars = Array(payload)
        
        if let freq = UInt64(String(chars[0..<11])) {
            DispatchQueue.main.async { self.frequency = freq }
        }
        
        if let modeVal = Int(String(chars[27])), let radioMode = RadioMode(catValue: modeVal) {
            DispatchQueue.main.async { self.mode = radioMode }
        }
    }
}

// MARK: - Radio Mode

enum RadioMode: String, CaseIterable {
    case lsb = "LSB"
    case usb = "USB"
    case cw = "CW"
    case fm = "FM"
    case am = "AM"
    case cwReverse = "CW-R"
    case unknown = "???"
    
    var catValue: Int {
        switch self {
        case .lsb: return 1
        case .usb: return 2
        case .cw: return 3
        case .fm: return 4
        case .am: return 5
        case .cwReverse: return 7
        case .unknown: return 0
        }
    }
    
    init?(catValue: Int) {
        switch catValue {
        case 1: self = .lsb
        case 2: self = .usb
        case 3: self = .cw
        case 4: self = .fm
        case 5: self = .am
        case 7: self = .cwReverse
        default: self = .unknown
        }
    }
}
