import Foundation
import Combine

/// Main view model that ties together CAT control and USB audio.
@MainActor
class RadioViewModel: ObservableObject {
    
    @Published var catController = CATController()
    @Published var audioManager = USBAudioManager()
    
    @Published var frequencyText: String = "7.074.000"
    @Published var statusMessage: String = "Disconnected"
    @Published var availablePorts: [String] = []
    
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        setupBindings()
        refreshPorts()
    }
    
    // MARK: - Actions
    
    func connect() {
        catController.autoConnect()
        do {
            try audioManager.startMonitoring()
        } catch {
            statusMessage = "Audio error: \(error.localizedDescription)"
        }
    }
    
    func connectToPort(_ path: String) {
        catController.connect(portPath: path)
        do {
            try audioManager.startMonitoring()
        } catch {
            statusMessage = "Audio error: \(error.localizedDescription)"
        }
    }
    
    func disconnect() {
        catController.disconnect()
        audioManager.stop()
    }
    
    func refreshPorts() {
        availablePorts = USBSerialPort.availablePorts()
    }
    
    func setFrequency(_ hz: UInt64) {
        catController.setFrequency(hz)
    }
    
    func setMode(_ mode: RadioMode) {
        catController.setMode(mode)
    }
    
    func toggleTransmit() {
        if catController.isTransmitting {
            catController.receive()
        } else {
            catController.transmit()
        }
    }
    
    // MARK: - Private
    
    private func setupBindings() {
        catController.$frequency
            .receive(on: RunLoop.main)
            .map { Self.formatFrequency($0) }
            .assign(to: &$frequencyText)
        
        catController.$connectionState
            .receive(on: RunLoop.main)
            .map { state -> String in
                switch state {
                case .disconnected: return "Disconnected"
                case .connecting: return "Connecting..."
                case .connected: return "Connected to (tr)uSDX"
                case .error(let msg): return "Error: \(msg)"
                }
            }
            .assign(to: &$statusMessage)
    }
    
    static func formatFrequency(_ hz: UInt64) -> String {
        guard hz > 0 else { return "----.---" }
        let mhz = hz / 1_000_000
        let khz = (hz % 1_000_000) / 1_000
        let h = hz % 1_000
        return String(format: "%d.%03d.%03d", mhz, khz, h)
    }
}
