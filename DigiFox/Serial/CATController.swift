//
//  CATController.swift
//  DigiFox
//
//  CAT (Computer Aided Transceiver) controller using Hamlib.
//  Supports all Hamlib rig models (~400 transceivers).
//  Falls back to Hamlib's built-in serial I/O.
//

import Foundation

/// Radio state
struct RadioState {
    var frequency: UInt64 = 0        // Hz
    var mode: String = ""            // e.g. "USB", "LSB", "DATA"
    var isTransmitting: Bool = false
    var isConnected: Bool = false
    var rigName: String = ""
}

/// CAT controller for radio communication using Hamlib
actor CATController {
    private var hamlibRig: HamlibRig?
    private(set) var state = RadioState()

    // MARK: - Connection

    /// Connect to a rig using Hamlib model ID
    func connect(modelId: Int, path: String, baudRate: Int = 9600) throws {
        disconnect()

        guard let rig = HamlibRig(modelId: modelId) else {
            throw CATError.initFailed(modelId: modelId)
        }

        rig.setPort(path: path, baudRate: baudRate)
        try rig.open()

        self.hamlibRig = rig
        state.isConnected = true
        state.rigName = rig.caps?.displayName ?? "Rig #\(modelId)"
    }

    /// Connect using first Digirig device found
    func connectDigirig(modelId: Int, baudRate: Int = 9600) throws {
        guard let device = SerialPort.findDigirig() else {
            throw SerialPortError.deviceNotFound
        }
        try connect(modelId: modelId, path: device.path, baudRate: baudRate)
    }

    /// Disconnect from rig
    func disconnect() {
        hamlibRig?.close()
        hamlibRig = nil
        state.isConnected = false
        state.isTransmitting = false
        state.rigName = ""
    }

    var isConnected: Bool { state.isConnected }

    // MARK: - PTT

    func pttOn() throws {
        guard let rig = hamlibRig else { throw CATError.notConnected }
        try rig.setPTT(true)
        state.isTransmitting = true
    }

    func pttOff() throws {
        guard let rig = hamlibRig else { throw CATError.notConnected }
        try rig.setPTT(false)
        state.isTransmitting = false
    }

    // MARK: - Frequency

    func setFrequency(_ hz: UInt64) throws {
        guard let rig = hamlibRig else { throw CATError.notConnected }
        try rig.setFrequency(Double(hz))
        state.frequency = hz
    }

    func getFrequency() throws -> UInt64 {
        guard let rig = hamlibRig else { throw CATError.notConnected }
        let freq = try rig.getFrequency()
        state.frequency = UInt64(freq)
        return state.frequency
    }

    // MARK: - Mode

    func setMode(_ mode: String) throws {
        guard let rig = hamlibRig else { throw CATError.notConnected }
        let hamlibMode = HamlibRig.modeFromString(mode)
        try rig.setMode(hamlibMode)
        state.mode = mode
    }

    func getMode() throws -> String {
        guard let rig = hamlibRig else { throw CATError.notConnected }
        let (mode, _) = try rig.getMode()
        let modeStr = modeToString(mode)
        state.mode = modeStr
        return modeStr
    }

    // MARK: - Helpers

    private func modeToString(_ mode: rmode_t) -> String {
        if mode == kRIG_MODE_USB { return "USB" }
        if mode == kRIG_MODE_LSB { return "LSB" }
        if mode == kRIG_MODE_CW  { return "CW" }
        if mode == kRIG_MODE_AM  { return "AM" }
        if mode == kRIG_MODE_FM  { return "FM" }
        if mode == kRIG_MODE_PKTUSB { return "DATA" }
        return "USB"
    }
}

// MARK: - Errors

enum CATError: LocalizedError {
    case notConnected
    case initFailed(modelId: Int)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Nicht mit Funkgerät verbunden"
        case .initFailed(let id):
            return "Hamlib Rig-Modell \(id) konnte nicht initialisiert werden"
        }
    }
}
