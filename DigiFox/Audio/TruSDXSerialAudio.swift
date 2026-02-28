import Foundation
import Combine

// MARK: - TruSDX Demuxer (testable, synchronous)

/// Pure demultiplexer for the (tr)uSDX CAT_STREAMING protocol.
///
/// Protocol (from usdx.ino firmware):
/// - Audio is sent as `US<samples>;` blocks: 8-bit unsigned PCM at 7812.5 Hz
/// - The byte 0x3B (';') never appears in audio data (firmware increments it to 0x3C)
/// - ';' only appears as CAT delimiter
///
/// State machine (from firmware Linux script):
///   State 0 (cat):       ';' → state 1; else accumulate CAT byte
///   State 1 (semicolon): 'U' → state 2; else start new CAT, state 0
///   State 2 (semicolonU):'S' → state 3 (audio); else forward "U"+byte as CAT, state 0
///   State 3 (audio):     ';' → state 1; else decode as audio sample
struct TruSDXDemuxer {

    struct Result {
        var audioSamples: [Float]
        var catResponses: [String]
    }

    private enum State {
        case cat
        case semicolon
        case semicolonU
        case audio
    }

    private var state: State = .cat
    private var catBuffer = ""

    /// Process incoming bytes and return demuxed audio samples and CAT responses.
    mutating func process(_ data: Data) -> Result {
        var audio = [Float]()
        var cat = [String]()

        for byte in data {
            switch state {
            case .cat:
                if byte == 0x3B { // ';'
                    if !catBuffer.isEmpty {
                        cat.append(catBuffer + ";")
                        catBuffer = ""
                    }
                    state = .semicolon
                } else {
                    catBuffer.append(Character(UnicodeScalar(byte)))
                }

            case .semicolon:
                if byte == UInt8(ascii: "U") {
                    state = .semicolonU
                } else {
                    catBuffer.append(Character(UnicodeScalar(byte)))
                    state = .cat
                }

            case .semicolonU:
                if byte == UInt8(ascii: "S") {
                    state = .audio
                } else {
                    catBuffer.append("U")
                    catBuffer.append(Character(UnicodeScalar(byte)))
                    state = .cat
                }

            case .audio:
                if byte == 0x3B { // ';'
                    state = .semicolon
                } else {
                    audio.append(Self.byteToSample(byte))
                }
            }
        }

        return Result(audioSamples: audio, catResponses: cat)
    }

    /// Reset the demuxer state
    mutating func reset() {
        state = .cat
        catBuffer = ""
    }

    /// Convert 8-bit unsigned PCM to float (-1.0 ... 1.0)
    static func byteToSample(_ byte: UInt8) -> Float {
        (Float(byte) - 128.0) / 128.0
    }

    /// Convert float (-1.0 ... 1.0) to 8-bit unsigned PCM, avoiding ';' (0x3B)
    static func sampleToByte(_ sample: Float) -> UInt8 {
        let clamped = max(-1.0, min(1.0, sample))
        var byte = UInt8(clamped * 127.0 + 128.0)
        if byte == 0x3B { byte = 0x3C } // firmware rule: never send ';' as audio
        return byte
    }
}

// MARK: - TruSDX Serial Audio Manager

/// Manages audio I/O over the (tr)uSDX serial connection using CAT_STREAMING.
class TruSDXSerialAudio: ObservableObject {

    /// Sample rate: 7812.5 Hz (20 MHz XTAL) or 6250 Hz (16 MHz)
    static let sampleRate20MHz: Double = 7812.5
    static let sampleRate16MHz: Double = 6250.0
    static let defaultSampleRate: Double = sampleRate20MHz
    static let requiredBaudRate: speed_t = 115200

    enum AudioState: Equatable {
        case idle
        case streaming
        case error(String)
    }

    @Published var state: AudioState = .idle
    @Published var inputLevel: Float = 0

    var onAudioReceived: (([Float]) -> Void)?
    var onCATResponse: ((String) -> Void)?
    var sampleRate: Double = defaultSampleRate

    private var serialPort: USBSerialPort?
    private var demuxer = TruSDXDemuxer()

    func attach(to port: USBSerialPort) {
        self.serialPort = port
        port.onDataReceived = { [weak self] data in
            self?.handleData(data)
        }
    }

    func startStreaming() {
        guard let port = serialPort, port.isConnected else {
            state = .error("Serial port not connected")
            return
        }
        try? port.write("UA1;")
        state = .streaming
        demuxer.reset()
    }

    func stopStreaming() {
        guard let port = serialPort, port.isConnected else { return }
        try? port.write("UA0;")
        state = .idle
        demuxer.reset()
    }

    func detach() {
        if state == .streaming { stopStreaming() }
        serialPort?.onDataReceived = nil
        serialPort = nil
        state = .idle
    }

    private func handleData(_ data: Data) {
        let result = demuxer.process(data)

        if !result.audioSamples.isEmpty {
            let rms = sqrt(result.audioSamples.reduce(0) { $0 + $1 * $1 } / Float(result.audioSamples.count))
            DispatchQueue.main.async {
                self.inputLevel = rms
                self.onAudioReceived?(result.audioSamples)
            }
        }

        for response in result.catResponses {
            DispatchQueue.main.async {
                self.onCATResponse?(response)
            }
        }
    }

    // MARK: - Resampling

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
