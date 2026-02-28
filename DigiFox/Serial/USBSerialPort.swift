import Foundation

/// Low-level USB serial port communication using POSIX termios.
/// Used to talk to USB CDC ACM devices like the (tr)uSDX transceiver.
class USBSerialPort {
    
    enum SerialError: Error, LocalizedError {
        case portNotFound
        case openFailed(String)
        case configurationFailed
        case readFailed
        case writeFailed
        case notConnected
        
        var errorDescription: String? {
            switch self {
            case .portNotFound: return "No USB serial port found"
            case .openFailed(let path): return "Failed to open port: \(path)"
            case .configurationFailed: return "Failed to configure serial port"
            case .readFailed: return "Failed to read from serial port"
            case .writeFailed: return "Failed to write to serial port"
            case .notConnected: return "Serial port not connected"
            }
        }
    }
    
    private var fileDescriptor: Int32 = -1
    private var readQueue: DispatchQueue
    private var isReading = false
    
    var isConnected: Bool { fileDescriptor >= 0 }
    var onDataReceived: ((Data) -> Void)?
    
    init() {
        readQueue = DispatchQueue(label: "com.digifox.serial.read", qos: .userInitiated)
    }
    
    deinit {
        disconnect()
    }
    
    /// Discover available USB serial ports
    static func availablePorts() -> [String] {
        let fileManager = FileManager.default
        let devPath = "/dev"
        
        guard let entries = try? fileManager.contentsOfDirectory(atPath: devPath) else {
            return []
        }
        
        return entries
            .filter { $0.hasPrefix("cu.usbmodem") || $0.hasPrefix("cu.usbserial") }
            .map { "\(devPath)/\($0)" }
    }
    
    /// Connect to a serial port at the given path and baud rate
    func connect(path: String, baudRate: speed_t = 38400) throws {
        disconnect()
        
        fileDescriptor = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fileDescriptor >= 0 else {
            throw SerialError.openFailed(path)
        }
        
        // Clear non-blocking after open
        var flags = fcntl(fileDescriptor, F_GETFL)
        flags &= ~O_NONBLOCK
        fcntl(fileDescriptor, F_SETFL, flags)
        
        // Configure serial port
        var settings = termios()
        guard tcgetattr(fileDescriptor, &settings) == 0 else {
            close(fileDescriptor)
            fileDescriptor = -1
            throw SerialError.configurationFailed
        }
        
        cfmakeraw(&settings)
        
        // 8N1 configuration
        settings.c_cflag |= UInt(CS8)
        settings.c_cflag &= ~UInt(PARENB)
        settings.c_cflag &= ~UInt(CSTOPB)
        settings.c_cflag |= UInt(CLOCAL | CREAD)
        
        // Set baud rate (TruSDX default: 38400)
        let speed = mapBaudRate(baudRate)
        cfsetispeed(&settings, speed)
        cfsetospeed(&settings, speed)
        
        // Read timeout: 1 second
        settings.c_cc.16 = 10  // VTIME = 1 second
        settings.c_cc.17 = 0   // VMIN = 0
        
        guard tcsetattr(fileDescriptor, TCSANOW, &settings) == 0 else {
            close(fileDescriptor)
            fileDescriptor = -1
            throw SerialError.configurationFailed
        }
        
        tcflush(fileDescriptor, TCIOFLUSH)
        startReading()
    }
    
    /// Disconnect from the serial port
    func disconnect() {
        isReading = false
        if fileDescriptor >= 0 {
            close(fileDescriptor)
            fileDescriptor = -1
        }
    }
    
    /// Write data to the serial port
    func write(_ data: Data) throws {
        guard isConnected else { throw SerialError.notConnected }
        
        let result = data.withUnsafeBytes { buffer in
            Darwin.write(fileDescriptor, buffer.baseAddress!, buffer.count)
        }
        
        guard result >= 0 else { throw SerialError.writeFailed }
    }
    
    /// Write a string command to the serial port
    func write(_ string: String) throws {
        guard let data = string.data(using: .ascii) else { return }
        try write(data)
    }
    
    // MARK: - Private
    
    private func startReading() {
        isReading = true
        readQueue.async { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 1024)
            while let self = self, self.isReading, self.isConnected {
                let bytesRead = read(self.fileDescriptor, &buffer, buffer.count)
                if bytesRead > 0 {
                    let data = Data(buffer[0..<bytesRead])
                    DispatchQueue.main.async {
                        self.onDataReceived?(data)
                    }
                } else if bytesRead < 0 && errno != EAGAIN {
                    break
                }
            }
        }
    }
    
    private func mapBaudRate(_ rate: speed_t) -> speed_t {
        switch rate {
        case 9600: return speed_t(B9600)
        case 19200: return speed_t(B19200)
        case 38400: return speed_t(B38400)
        case 57600: return speed_t(B57600)
        case 115200: return speed_t(B115200)
        default: return speed_t(B38400)
        }
    }
}
