//
//  SerialPort.swift
//  DigiFox
//
//  Swift wrapper around IOKitUSBSerial for async serial communication.
//  Provides device discovery, read/write, and PTT control via RTS.
//

import Foundation

/// Information about a discovered USB serial device
struct SerialDeviceInfo: Identifiable, CustomStringConvertible {
    let id: String       // device path
    let path: String     // e.g. /dev/tty.usbserial-0001
    let name: String     // e.g. "CP2102 USB to UART Bridge"
    let vendorID: UInt16
    let productID: UInt16

    /// Whether this looks like a Digirig Mobile (CP210x, VID=0x10C4)
    var isDigirig: Bool {
        vendorID == 0x10C4 // Silicon Labs
    }

    /// Whether this looks like a (tr)uSDX (CH340, VID=0x1A86)
    var isTruSDX: Bool {
        vendorID == 0x1A86 // QinHeng CH340/CH341
    }

    var description: String {
        "\(name) (\(path)) [VID=0x\(String(vendorID, radix: 16)) PID=0x\(String(productID, radix: 16))]"
    }
}

/// Serial port communication errors
enum SerialPortError: LocalizedError {
    case ioKitNotAvailable
    case deviceNotFound
    case openFailed(String)
    case notOpen
    case writeFailed(String)
    case readFailed(String)
    case controlFailed(String)

    var errorDescription: String? {
        switch self {
        case .ioKitNotAvailable: return "IOKit is not available on this device"
        case .deviceNotFound: return "No USB serial device found"
        case .openFailed(let msg): return "Failed to open port: \(msg)"
        case .notOpen: return "Serial port is not open"
        case .writeFailed(let msg): return "Write failed: \(msg)"
        case .readFailed(let msg): return "Read failed: \(msg)"
        case .controlFailed(let msg): return "Control signal failed: \(msg)"
        }
    }
}

/// Async Swift wrapper for USB serial communication
actor SerialPort {
    private var port: IOKitUSBSerial?
    private let queue = DispatchQueue(label: "serial.port.io", qos: .userInitiated)

    /// Whether running in the iOS Simulator (IOKit works via macOS host)
    static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    /// Whether IOKit serial is available on this iOS device
    static var isAvailable: Bool {
        IOKitUSBSerial.isAvailable()
    }

    /// Discover all connected USB serial devices.
    /// In the Simulator, also checks for virtual serial ports (e.g. from socat).
    static func discoverDevices() -> [SerialDeviceInfo] {
        var devices = [SerialDeviceInfo]()

        // IOKit discovery (works on device and in Simulator via macOS host)
        if IOKitUSBSerial.isAvailable() {
            let objcDevices = IOKitUSBSerial.discoverDevices()
            devices = objcDevices.compactMap { dev -> SerialDeviceInfo? in
                // Filter out system/debug/bluetooth serial ports
                let pathLower = dev.path.lowercased()
                let nameLower = dev.name.lowercased()
                if pathLower.contains("bluetooth") || nameLower.contains("bluetooth") { return nil }
                if pathLower.contains("debug") || nameLower.contains("debug") { return nil }
                if pathLower.contains("wlan") || nameLower.contains("wlan") { return nil }
                return SerialDeviceInfo(
                    id: dev.path,
                    path: dev.path,
                    name: dev.name,
                    vendorID: dev.vendorID,
                    productID: dev.productID
                )
            }
        }

        #if targetEnvironment(simulator)
        // In Simulator: also detect virtual serial ports (socat pty pairs)
        // Usage: socat -d -d pty,raw,echo=0,link=/tmp/vserial0 pty,raw,echo=0,link=/tmp/vserial1
        for path in ["/tmp/vserial0", "/tmp/vserial1"] {
            if FileManager.default.fileExists(atPath: path),
               !devices.contains(where: { $0.path == path }) {
                devices.append(SerialDeviceInfo(
                    id: path, path: path,
                    name: "Virtual Serial (Simulator)",
                    vendorID: 0x10C4, productID: 0xEA60 // Fake Digirig IDs
                ))
            }
        }
        // Also pick up manually specified debug port via environment variable
        if let debugPort = ProcessInfo.processInfo.environment["DIGIFOX_SERIAL_PORT"],
           FileManager.default.fileExists(atPath: debugPort),
           !devices.contains(where: { $0.path == debugPort }) {
            devices.append(SerialDeviceInfo(
                id: debugPort, path: debugPort,
                name: "Debug Serial Port",
                vendorID: 0x10C4, productID: 0xEA60
            ))
        }
        #endif

        return devices
    }

    /// Find the first Digirig device, if connected
    static func findDigirig() -> SerialDeviceInfo? {
        discoverDevices().first { $0.isDigirig }
    }

    /// Whether the port is currently open
    var isOpen: Bool {
        port?.isOpen ?? false
    }

    /// Open a serial port
    func open(path: String, baudRate: UInt = 9600) throws {
        close()
        do {
            let p = try IOKitUSBSerial(path: path, baudRate: baudRate)
            port = p
        } catch {
            throw SerialPortError.openFailed(error.localizedDescription)
        }
    }

    /// Open the first Digirig device found
    func openDigirig(baudRate: UInt = 9600) throws {
        guard let device = Self.findDigirig() else {
            throw SerialPortError.deviceNotFound
        }
        try open(path: device.path, baudRate: baudRate)
    }

    /// Close the port
    func close() {
        port?.close()
        port = nil
    }

    /// Write raw data
    func write(_ data: Data) throws {
        guard let port, port.isOpen else { throw SerialPortError.notOpen }
        var error: NSError?
        let result = port.write(data, error: &error)
        if result < 0 { throw SerialPortError.writeFailed(error?.localizedDescription ?? "Unknown") }
    }

    /// Write a string command (UTF-8)
    func write(_ string: String) throws {
        guard let port, port.isOpen else { throw SerialPortError.notOpen }
        var error: NSError?
        let result = port.write(string, error: &error)
        if result < 0 { throw SerialPortError.writeFailed(error?.localizedDescription ?? "Unknown") }
    }

    /// Read available data (non-blocking, returns empty Data if nothing available)
    func read(maxLength: UInt = 1024) throws -> Data {
        guard let port, port.isOpen else { throw SerialPortError.notOpen }
        return try port.readData(withMaxLength: maxLength)
    }

    /// Read with timeout
    func read(maxLength: UInt = 1024, timeout: TimeInterval = 1.0) throws -> Data {
        guard let port, port.isOpen else { throw SerialPortError.notOpen }
        return try port.readData(withMaxLength: maxLength, timeout: timeout)
    }

    /// Send a command and read the response
    func sendCommand(_ command: String, timeout: TimeInterval = 1.0) throws -> String {
        try write(command)
        let responseData = try read(maxLength: 1024, timeout: timeout)
        return String(data: responseData, encoding: .utf8) ?? ""
    }

    // MARK: - PTT Control (Digirig uses RTS for hardware PTT)

    /// Activate PTT (key transmitter) via RTS line
    func pttOn() throws {
        guard let port, port.isOpen else { throw SerialPortError.notOpen }
        do { try port.setRTS(true) }
        catch { throw SerialPortError.controlFailed(error.localizedDescription) }
    }

    /// Deactivate PTT (unkey transmitter) via RTS line
    func pttOff() throws {
        guard let port, port.isOpen else { throw SerialPortError.notOpen }
        do { try port.setRTS(false) }
        catch { throw SerialPortError.controlFailed(error.localizedDescription) }
    }

    /// Set DTR line state
    func setDTR(_ enabled: Bool) throws {
        guard let port, port.isOpen else { throw SerialPortError.notOpen }
        do { try port.setDTR(enabled) }
        catch { throw SerialPortError.controlFailed(error.localizedDescription) }
    }
}
