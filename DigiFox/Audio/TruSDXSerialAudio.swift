import Foundation
import Combine

/// Handles audio I/O over the (tr)uSDX serial connection.
///
/// The (tr)uSDX sends both CAT commands and audio data over the same USB CDC serial port.
/// - CAT commands: ASCII text terminated by ';'
/// - Audio data: raw 8-bit unsigned PCM at ~4808 Hz sample rate
///
/// This manager demultiplexes the incoming stream, forwarding CAT responses
/// to a callback and converting audio samples for processing.
class TruSDXSerialAudio: ObservableObject {

    // (tr)uSDX audio parameters
    static let sampleRate: Double = 4807.69
    static let bitsPerSample = 8
    static let pcmBias: Float = 128.0    // unsigned 8-bit center

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

    private var serialPort: USBSerialPort?
    private var catBuffer = Data()

    // MARK: - Lifecycle

    /// Attach to an already-opened serial port and start demuxing
    func attach(to port: USBSerialPort) {
        self.serialPort = port
        port.onDataReceived = { [weak self] data in
            self?.demux(data)
        }
        state = .streaming
    }

    /// Detach from the serial port
    func detach() {
        serialPort?.onDataReceived = nil
        serialPort = nil
        state = .idle
    }

    // MARK: - TX Audio

    /// Send audio samples to the (tr)uSDX for transmission.
    /// Converts float samples (-1.0...1.0) to 8-bit unsigned PCM.
    func sendAudio(_ samples: [Float]) {
        guard let port = serialPort, port.isConnected else { return }

        var bytes = Data(capacity: samples.count)
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            let byte = UInt8(clamped * 127.0 + Self.pcmBias)
            bytes.append(byte)
        }

        try? port.write(bytes)
    }

    /// Resample from standard sample rate (e.g. 48000) down to TruSDX rate (~4808 Hz)
    static func downsample(_ samples: [Float], from sourceSR: Double, to targetSR: Double = sampleRate) -> [Float] {
        let ratio = sourceSR / targetSR
        let outputCount = Int(Double(samples.count) / ratio)
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

    /// Upsample from TruSDX rate (~4808 Hz) to standard sample rate (e.g. 48000)
    static func upsample(_ samples: [Float], from sourceSR: Double = sampleRate, to targetSR: Double) -> [Float] {
        let ratio = targetSR / sourceSR
        let outputCount = Int(Double(samples.count) * ratio)
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

    // MARK: - Demultiplexer

    /// Separate incoming serial data into CAT responses and audio samples.
    ///
    /// Heuristic: bytes in the printable ASCII range (0x20-0x7E) that form
    /// semicolon-terminated strings are CAT responses. All other bytes are
    /// treated as 8-bit unsigned PCM audio samples.
    private func demux(_ data: Data) {
        var audioSamples = [Float]()

        for byte in data {
            if isPrintableASCII(byte) || byte == 0x0A || byte == 0x0D {
                // Accumulate potential CAT data
                catBuffer.append(byte)

                if byte == UInt8(ascii: ";") {
                    // Complete CAT response
                    if let response = String(data: catBuffer, encoding: .ascii) {
                        DispatchQueue.main.async {
                            self.onCATResponse?(response)
                        }
                    }
                    catBuffer.removeAll()
                }

                // Prevent buffer overflow from malformed data
                if catBuffer.count > 256 {
                    // Not a valid CAT response, treat accumulated bytes as audio
                    audioSamples.append(contentsOf: catBuffer.map { byteToSample($0) })
                    catBuffer.removeAll()
                }
            } else {
                // Flush any partial CAT buffer as audio (was not a valid command)
                if !catBuffer.isEmpty {
                    audioSamples.append(contentsOf: catBuffer.map { byteToSample($0) })
                    catBuffer.removeAll()
                }
                // Audio sample
                audioSamples.append(byteToSample(byte))
            }
        }

        if !audioSamples.isEmpty {
            // Calculate RMS level
            let rms = sqrt(audioSamples.reduce(0) { $0 + $1 * $1 } / Float(audioSamples.count))
            DispatchQueue.main.async {
                self.inputLevel = rms
                self.onAudioReceived?(audioSamples)
            }
        }
    }

    /// Convert unsigned 8-bit PCM to float (-1.0 ... 1.0)
    private func byteToSample(_ byte: UInt8) -> Float {
        return (Float(byte) - Self.pcmBias) / Self.pcmBias
    }

    /// Check if byte is printable ASCII (space through tilde)
    private func isPrintableASCII(_ byte: UInt8) -> Bool {
        return byte >= 0x20 && byte <= 0x7E
    }
}
