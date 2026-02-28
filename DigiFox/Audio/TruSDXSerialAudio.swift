import Foundation
import Combine

/// Handles audio I/O over the (tr)uSDX serial connection using the CAT_STREAMING protocol.
///
/// Protocol details (from usdx.ino firmware):
/// - Enable streaming:  send `UA1;`
/// - Disable streaming: send `UA0;`
/// - RX audio is sent as `US<audio bytes>;` blocks at 7812 Hz, 8-bit unsigned PCM
/// - The byte value 0x3B (';') is never sent as audio data (incremented to 0x3C)
/// - CAT responses are interleaved: `;US[audio...];[CAT response];US[audio...];`
/// - Baud rate must be 115200 for streaming
///
/// Demux state machine (from firmware source):
///   State 0 (CAT):   ';' → state 1; else forward to CAT
///   State 1 (after ';'): 'U' → state 2; else forward to CAT, state 0
///   State 2 (after ';U'): 'S' → state 3 (audio); else forward "U"+byte to CAT, state 0
///   State 3 (audio): ';' → state 1 (end of audio block); else → audio sample
class TruSDXSerialAudio: ObservableObject {

    /// Sample rate depends on crystal frequency:
    /// - 20 MHz crystal (standard TruSDX): 7812.5 Hz
    /// - 16 MHz crystal (Arduino Uno/Nano): 6250 Hz
    static let sampleRate20MHz: Double = 7812.5
    static let sampleRate16MHz: Double = 6250.0
    static let defaultSampleRate: Double = sampleRate20MHz

    /// Required baud rate for CAT_STREAMING
    static let requiredBaudRate: speed_t = 115200

    enum State: Equatable {
        case idle
        case streaming
        case error(String)
    }

    @Published var state: State = .idle
    @Published var inputLevel: Float = 0

    /// Called with decoded float audio samples (range -1.0 ... 1.0)
    var onAudioReceived: (([Float]) -> Void)?

    /// Called with complete CAT response strings (e.g. "FA00007074000;")
    var onCATResponse: ((String) -> Void)?

    var sampleRate: Double = defaultSampleRate

    private var serialPort: USBSerialPort?
    private var demuxState: DemuxState = .cat
    private var catBuffer = ""
    private var audioBuffer = [Float]()

    // Demux state machine matching the firmware
    private enum DemuxState {
        case cat        // State 0: normal CAT data
        case semicolon  // State 1: just saw ';'
        case semicolonU // State 2: just saw ';U'
        case audio      // State 3: receiving audio samples
    }

    // MARK: - Lifecycle

    /// Attach to an already-opened serial port and start demuxing
    func attach(to port: USBSerialPort) {
        self.serialPort = port
        port.onDataReceived = { [weak self] data in
            self?.processIncoming(data)
        }
    }

    /// Send UA1; to enable audio streaming from the (tr)uSDX
    func startStreaming() {
        guard let port = serialPort, port.isConnected else {
            state = .error("Serial port not connected")
            return
        }
        try? port.write("UA1;")
        state = .streaming
        demuxState = .cat
    }

    /// Send UA0; to disable audio streaming
    func stopStreaming() {
        guard let port = serialPort, port.isConnected else { return }
        try? port.write("UA0;")
        state = .idle
        demuxState = .cat
    }

    /// Detach from the serial port
    func detach() {
        if state == .streaming { stopStreaming() }
        serialPort?.onDataReceived = nil
        serialPort = nil
        state = .idle
    }

    // MARK: - Demultiplexer (matching firmware state machine)

    private func processIncoming(_ data: Data) {
        var audioSamples = [Float]()

        for byte in data {
            switch demuxState {
            case .cat:
                // State 0: looking for ';' to transition
                if byte == 0x3B { // ';'
                    // Flush any accumulated CAT data as a complete response
                    if !catBuffer.isEmpty {
                        let response = catBuffer + ";"
                        catBuffer = ""
                        DispatchQueue.main.async {
                            self.onCATResponse?(response)
                        }
                    }
                    demuxState = .semicolon
                } else {
                    catBuffer.append(Character(UnicodeScalar(byte)))
                }

            case .semicolon:
                // State 1: just saw ';', check for 'U'
                if byte == UInt8(ascii: "U") {
                    demuxState = .semicolonU
                } else {
                    // Not a US prefix, this byte is part of a new CAT command
                    catBuffer.append(Character(UnicodeScalar(byte)))
                    demuxState = .cat
                }

            case .semicolonU:
                // State 2: saw ';U', check for 'S'
                if byte == UInt8(ascii: "S") {
                    demuxState = .audio
                } else {
                    // Not 'US', forward 'U' + this byte as CAT data
                    catBuffer.append("U")
                    catBuffer.append(Character(UnicodeScalar(byte)))
                    demuxState = .cat
                }

            case .audio:
                // State 3: audio data until next ';'
                if byte == 0x3B { // ';'
                    demuxState = .semicolon
                } else {
                    // Convert 8-bit unsigned PCM to float (-1.0 ... 1.0)
                    let sample = (Float(byte) - 128.0) / 128.0
                    audioSamples.append(sample)
                }
            }
        }

        if !audioSamples.isEmpty {
            let rms = sqrt(audioSamples.reduce(0) { $0 + $1 * $1 } / Float(audioSamples.count))
            DispatchQueue.main.async {
                self.inputLevel = rms
                self.onAudioReceived?(audioSamples)
            }
        }
    }

    // MARK: - Resampling Utilities

    /// Upsample from TruSDX rate (~7812 Hz) to standard sample rate (e.g. 48000)
    static func upsample(_ samples: [Float], from sourceSR: Double = defaultSampleRate, to targetSR: Double) -> [Float] {
        let ratio = targetSR / sourceSR
        let outputCount = Int(Double(samples.count) * ratio)
        guard outputCount > 0 else { return [] }
        var output = [Float](repeating: 0, count: outputCount)

        for i in 0..<outputCount {
            let srcIndex = Double(i) / ratio
            let idx = Int(srcIndex)
            let frac = Float(srcIndex - Double(idx))

            if idx + 1 < samples.count {
                output[i] = samples[idx] * (1.0 - frac) + samples[idx + 1] * frac
            } else if idx < samples.count {
                output[i] = samples[idx]
            }
        }
        return output
    }

    /// Downsample from standard sample rate (e.g. 48000) to TruSDX rate (~7812 Hz)
    static func downsample(_ samples: [Float], from sourceSR: Double, to targetSR: Double = defaultSampleRate) -> [Float] {
        let ratio = sourceSR / targetSR
        let outputCount = Int(Double(samples.count) / ratio)
        guard outputCount > 0 else { return [] }
        var output = [Float](repeating: 0, count: outputCount)

        for i in 0..<outputCount {
            let srcIndex = Double(i) * ratio
            let idx = Int(srcIndex)
            let frac = Float(srcIndex - Double(idx))

            if idx + 1 < samples.count {
                output[i] = samples[idx] * (1.0 - frac) + samples[idx + 1] * frac
            } else if idx < samples.count {
                output[i] = samples[idx]
            }
        }
        return output
    }
}
