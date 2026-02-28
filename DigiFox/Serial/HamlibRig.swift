//
//  HamlibRig.swift
//  JS8Call
//
//  Swift wrapper around the Hamlib C library for transceiver control.
//  Provides model enumeration, rig init/open/close, frequency, mode, and PTT.
//

import Foundation

// Swift constants for C macros not importable by Swift
let kRIG_VFO_CURR: vfo_t   = 1 << 29
let kRIG_MODE_AM: rmode_t   = 1 << 0
let kRIG_MODE_CW: rmode_t   = 1 << 1
let kRIG_MODE_USB: rmode_t  = 1 << 2
let kRIG_MODE_LSB: rmode_t  = 1 << 3
let kRIG_MODE_FM: rmode_t   = 1 << 5
let kRIG_MODE_PKTUSB: rmode_t = 1 << 11

// MARK: - Rig Model Info

/// Information about a supported Hamlib rig model
struct HamlibModelInfo: Identifiable, Hashable {
    let id: Int          // rig_model_t
    let name: String     // model_name
    let manufacturer: String // mfg_name
    let version: String

    var displayName: String { "\(manufacturer) \(name)" }
}

// MARK: - Hamlib Wrapper

/// Swift wrapper for Hamlib rig control
final class HamlibRig {
    private var rig: UnsafeMutablePointer<s_rig>?
    let modelId: Int

    private static var backendsLoaded = false

    /// Ensure all Hamlib backends are registered (call once)
    static func loadBackends() {
        guard !backendsLoaded else { return }
        rig_load_all_backends()
        backendsLoaded = true
    }

    /// List all registered rig models
    static func listModels() -> [HamlibModelInfo] {
        loadBackends()

        var models: [HamlibModelInfo] = []

        let callback: @convention(c) (
            UnsafePointer<rig_caps>?,
            UnsafeMutableRawPointer?
        ) -> Int32 = { capsPtr, contextPtr in
            guard let capsPtr = capsPtr,
                  let ctx = contextPtr else { return 1 }
            let caps = capsPtr.pointee
            let modelsPtr = ctx.assumingMemoryBound(to: [HamlibModelInfo].self)

            // Safely handle potentially NULL C strings
            let name: String
            if let p = caps.model_name { name = String(cString: p) } else { name = "Unknown" }
            let mfg: String
            if let p = caps.mfg_name { mfg = String(cString: p) } else { mfg = "Unknown" }
            let ver: String
            if let p = caps.version { ver = String(cString: p) } else { ver = "" }

            // Skip stub entries with model 0
            guard caps.rig_model > 0 else { return 1 }

            let info = HamlibModelInfo(
                id: Int(caps.rig_model),
                name: name,
                manufacturer: mfg,
                version: ver
            )
            modelsPtr.pointee.append(info)
            return 1 // continue iteration
        }

        withUnsafeMutablePointer(to: &models) { ptr in
            rig_list_foreach(callback, ptr)
        }

        return models.sorted { $0.displayName < $1.displayName }
    }

    /// Initialize with a Hamlib model ID
    init?(modelId: Int) {
        Self.loadBackends()
        guard let r = rig_init(rig_model_t(modelId)) else { return nil }
        self.rig = r
        self.modelId = modelId
    }

    deinit {
        close()
        if let rig {
            rig_cleanup(rig)
        }
    }

    // MARK: - Connection

    /// Configure serial port path and baud rate before open()
    func setPort(path: String, baudRate: Int = 9600) {
        guard let rig else { return }
        path.withCString { cPath in
            withUnsafeMutablePointer(to: &rig.pointee.state.rigport.pathname) { pathPtr in
                let buf = UnsafeMutableRawPointer(pathPtr).assumingMemoryBound(to: CChar.self)
                strncpy(buf, cPath, Int(HAMLIB_FILPATHLEN) - 1)
                buf[Int(HAMLIB_FILPATHLEN) - 1] = 0
            }
        }
        rig.pointee.state.rigport.parm.serial.rate = Int32(baudRate)
    }

    /// Open connection to the rig
    func open() throws {
        guard let rig else { throw HamlibError.notInitialized }
        let result = rig_open(rig)
        guard result == Int32(RIG_OK.rawValue) else {
            throw HamlibError.hamlibError(code: Int(result))
        }
    }

    /// Close connection
    func close() {
        guard let rig else { return }
        rig_close(rig)
    }

    /// Whether the rig is currently open
    var isOpen: Bool {
        guard let rig else { return false }
        return rig.pointee.state.comm_state != 0
    }

    // MARK: - Frequency

    /// Set frequency in Hz
    func setFrequency(_ hz: Double, vfo: vfo_t = kRIG_VFO_CURR) throws {
        guard let rig else { throw HamlibError.notInitialized }
        let result = rig_set_freq(rig, vfo, freq_t(hz))
        guard result == Int32(RIG_OK.rawValue) else {
            throw HamlibError.hamlibError(code: Int(result))
        }
    }

    /// Get current frequency in Hz
    func getFrequency(vfo: vfo_t = kRIG_VFO_CURR) throws -> Double {
        guard let rig else { throw HamlibError.notInitialized }
        var freq: freq_t = 0
        let result = rig_get_freq(rig, vfo, &freq)
        guard result == Int32(RIG_OK.rawValue) else {
            throw HamlibError.hamlibError(code: Int(result))
        }
        return freq
    }

    // MARK: - Mode

    /// Set operating mode (use RIG_MODE_USB, RIG_MODE_LSB, RIG_MODE_PKTUSB, etc.)
    func setMode(_ mode: rmode_t, width: pbwidth_t = 0, vfo: vfo_t = kRIG_VFO_CURR) throws {
        guard let rig else { throw HamlibError.notInitialized }
        let result = rig_set_mode(rig, vfo, mode, width)
        guard result == Int32(RIG_OK.rawValue) else {
            throw HamlibError.hamlibError(code: Int(result))
        }
    }

    /// Get current mode and passband width
    func getMode(vfo: vfo_t = kRIG_VFO_CURR) throws -> (mode: rmode_t, width: pbwidth_t) {
        guard let rig else { throw HamlibError.notInitialized }
        var mode: rmode_t = 0
        var width: pbwidth_t = 0
        let result = rig_get_mode(rig, vfo, &mode, &width)
        guard result == Int32(RIG_OK.rawValue) else {
            throw HamlibError.hamlibError(code: Int(result))
        }
        return (mode, width)
    }

    // MARK: - PTT

    /// Activate/deactivate PTT
    func setPTT(_ on: Bool, vfo: vfo_t = kRIG_VFO_CURR) throws {
        guard let rig else { throw HamlibError.notInitialized }
        let pttVal: ptt_t = on ? RIG_PTT_ON : RIG_PTT_OFF
        let result = rig_set_ptt(rig, vfo, pttVal)
        guard result == Int32(RIG_OK.rawValue) else {
            throw HamlibError.hamlibError(code: Int(result))
        }
    }

    /// Get current PTT state
    func getPTT(vfo: vfo_t = kRIG_VFO_CURR) throws -> Bool {
        guard let rig else { throw HamlibError.notInitialized }
        var ptt: ptt_t = RIG_PTT_OFF
        let result = rig_get_ptt(rig, vfo, &ptt)
        guard result == Int32(RIG_OK.rawValue) else {
            throw HamlibError.hamlibError(code: Int(result))
        }
        return ptt != RIG_PTT_OFF
    }

    // MARK: - Morse / CW

    /// Send Morse code text — the rig keys CW automatically
    func sendMorse(_ text: String, vfo: vfo_t = kRIG_VFO_CURR) throws {
        guard let rig else { throw HamlibError.notInitialized }
        let result = rig_send_morse(rig, vfo, text)
        guard result == Int32(RIG_OK.rawValue) else {
            throw HamlibError.hamlibError(code: Int(result))
        }
    }

    /// Stop Morse transmission
    func stopMorse(vfo: vfo_t = kRIG_VFO_CURR) throws {
        guard let rig else { throw HamlibError.notInitialized }
        let result = rig_stop_morse(rig, vfo)
        guard result == Int32(RIG_OK.rawValue) else {
            throw HamlibError.hamlibError(code: Int(result))
        }
    }

    // MARK: - Model Info

    /// Get capabilities of the initialized rig
    var caps: HamlibModelInfo? {
        guard let rig, let capsPtr = rig.pointee.caps else { return nil }
        let c = capsPtr.pointee
        return HamlibModelInfo(
            id: Int(c.rig_model),
            name: c.model_name.map { String(cString: $0) } ?? "Unknown",
            manufacturer: c.mfg_name.map { String(cString: $0) } ?? "Unknown",
            version: c.version.map { String(cString: $0) } ?? ""
        )
    }

    /// Default baud rate from rig capabilities
    var defaultBaudRate: Int {
        guard let rig, let capsPtr = rig.pointee.caps else { return 9600 }
        let rate = Int(capsPtr.pointee.serial_rate_max)
        return rate > 0 ? rate : 9600
    }
}

// MARK: - Hamlib Mode Helpers

extension HamlibRig {
    /// Convert mode string to Hamlib rmode_t
    static func modeFromString(_ mode: String) -> rmode_t {
        switch mode.uppercased() {
        case "USB":  return kRIG_MODE_USB
        case "LSB":  return kRIG_MODE_LSB
        case "CW":   return kRIG_MODE_CW
        case "AM":   return kRIG_MODE_AM
        case "FM":   return kRIG_MODE_FM
        case "DATA", "PKTUSB": return kRIG_MODE_PKTUSB
        default:     return kRIG_MODE_USB
        }
    }
}

// MARK: - Errors

enum HamlibError: LocalizedError {
    case notInitialized
    case hamlibError(code: Int)

    var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "Rig nicht initialisiert"
        case .hamlibError(let code):
            return String(cString: rigerror(Int32(code)))
        }
    }
}
