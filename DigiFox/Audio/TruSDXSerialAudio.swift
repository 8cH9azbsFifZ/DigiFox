import Foundation
import Combine
import QuartzCore

// MARK: - TruSDX Demuxer (testable, synchronous)

/// Pure demultiplexer for the (tr)uSDX CAT_STREAMING protocol.
///
/// Protocol reference: https://dl2man.de/5-trusdx-details/
///
/// Supported TS-480 CAT commands:
///   FA; FAnnnnnn;  - Get/Set Frequency in Hz
///   MD; MDn;       - Get/Set Mode (1=LSB, 2=USB, 3=CW, 4=FM, 5=AM)
///   IF;            - Get transceiver status (Frequency, Mode)
///   TX0;           - Set TX (transmit) state
///   TX2;           - Set Tune state (mode must be CW)
///   RX;            - Set RX (receive) state
///   ID;            - Get transceiver ID: 020 (TS-480 emulation)
///
/// CAT Streaming extensions:
///   UA0;           - Streaming OFF (CAT only)
///   UA1;           - Streaming ON, speaker ON
///   UA2;           - Streaming ON, speaker OFF
///   USnnnnn…;      - Audio data block (U8 unsigned bytes until ';')
///
/// Audio stream details:
///   - RX sample rate: 7825 Hz
///   - TX sample rate: 11520 Hz (or lower for equidistant continuous sending)
///   - 8-bit unsigned PCM, 46 dB dynamic range
///   - ';' (0x3B) never appears in audio data (firmware increments to 0x3C)
///   - Audio may be interrupted by CAT at any ';', resumed with ;US
///
/// Serial port settings: 115200 baud, 8N1, No flow control
///   - DTR should be HIGH
///   - RTS should be LOW on RX, may be HIGH to key CW/PTT
///
/// State machine:
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
///
/// Reference: https://dl2man.de/5-trusdx-details/
///
/// RX flow: TruSDX sends ;US<audio>; blocks → demux → upsample 7825→12000 Hz → codec
/// TX flow: codec → downsample 12000→11520 Hz → encode U8 → ;US<audio>; → TruSDX
class TruSDXSerialAudio: ObservableObject {

    /// RX sample rate from (tr)uSDX: 7825 Hz
    static let rxSampleRate: Double = 7825.0
    /// TX sample rate to (tr)uSDX: 11520 Hz
    static let txSampleRate: Double = 11520.0
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

    private var serialPort: SerialPort?
    private var demuxer = TruSDXDemuxer()
    private var readTask: Task<Void, Never>?

    func attach(to port: SerialPort) {
        self.serialPort = port
    }

    func startStreaming() {
        guard let port = serialPort else {
            print("[TruSDX-Audio] startStreaming: no serial port attached")
            state = .error("Serial port not connected")
            return
        }
        state = .streaming
        demuxer.reset()
        print("[TruSDX-Audio] startStreaming: sending UA1;")
        readTask = Task { [weak self] in
            do {
                try await port.write("UA1;")
                print("[TruSDX-Audio] startStreaming: UA1; sent OK")
            } catch {
                print("[TruSDX-Audio] startStreaming: UA1; FAILED: \(error)")
                await MainActor.run { self?.state = .error("Failed to start streaming: \(error.localizedDescription)") }
                return
            }
            var totalSamples = 0
            var totalReads = 0
            while !Task.isCancelled {
                guard let self else { break }
                let isOpen = await port.isOpen
                guard isOpen else {
                    print("[TruSDX-Audio] readLoop: port closed, stopping")
                    break
                }
                do {
                    let data = try await port.read(maxLength: 1024)
                    if !data.isEmpty {
                        totalReads += 1
                        let beforeSamples = totalSamples
                        self.handleData(data)
                        // Count samples from demuxer (approximate via data size)
                        if totalReads % 500 == 0 {
                            print("[TruSDX-Audio] readLoop: \(totalReads) reads, \(data.count) bytes last read")
                        }
                    }
                } catch {
                    print("[TruSDX-Audio] readLoop: read error: \(error)")
                    break
                }
                try? await Task.sleep(nanoseconds: 1_000_000) // 1ms
            }
            print("[TruSDX-Audio] readLoop: ended after \(totalReads) reads")
        }
    }

    func stopStreaming() {
        print("[TruSDX-Audio] stopStreaming")
        readTask?.cancel()
        readTask = nil
        guard let port = serialPort else { return }
        Task { try? await port.write("UA0;") }
        state = .idle
        demuxer.reset()
    }

    /// Send TX audio: downsample to TX rate, encode as US blocks.
    /// Awaitable — returns only after all audio has been sent.
    func sendAudio(_ samples: [Float], fromSampleRate: Double = 12000) async {
        guard let port = serialPort else {
            print("[TruSDX-Audio] sendAudio: no serial port attached")
            return
        }
        let downsampled = Self.downsample(samples, from: fromSampleRate, to: Self.txSampleRate)
        print("[TruSDX-Audio] sendAudio: \(samples.count) samples @ \(fromSampleRate)Hz → \(downsampled.count) samples @ \(Self.txSampleRate)Hz")

        // Pause read loop during TX to avoid actor contention
        let wasStreaming = readTask != nil
        if wasStreaming {
            print("[TruSDX-Audio] sendAudio: pausing readTask for TX")
            readTask?.cancel()
            readTask = nil
        }

        let chunkSize = 128
        var chunksSent = 0
        var offset = 0
        let txStart = CACurrentMediaTime()

        while offset < downsampled.count {
            let end = min(offset + chunkSize, downsampled.count)
            var payload = Data([0x3B, UInt8(ascii: "U"), UInt8(ascii: "S")]) // ;US prefix
            for i in offset..<end {
                payload.append(TruSDXDemuxer.sampleToByte(downsampled[i]))
            }
            do {
                try await port.write(payload)
            } catch {
                print("[TruSDX-Audio] sendAudio: write error at chunk \(chunksSent): \(error)")
                break
            }
            chunksSent += 1
            let samplesInChunk = end - offset
            offset = end
            // Pace to match TX sample rate
            let sleepNs = UInt64(Double(samplesInChunk) / Self.txSampleRate * 1_000_000_000)
            try? await Task.sleep(nanoseconds: sleepNs)
        }

        let elapsed = CACurrentMediaTime() - txStart
        print("[TruSDX-Audio] sendAudio: done — \(chunksSent) chunks in \(String(format: "%.2f", elapsed))s")

        // Resume read loop after TX
        if wasStreaming {
            print("[TruSDX-Audio] sendAudio: resuming readTask after TX")
            startStreaming()
        }
    }

    func detach() {
        if state == .streaming { stopStreaming() }
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

    /// Upsample RX audio from TruSDX rate (7825 Hz) to codec rate (e.g. 12000 Hz)
    static func upsample(_ samples: [Float], from sourceSR: Double = rxSampleRate, to targetSR: Double) -> [Float] {
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

    /// Downsample TX audio from codec rate (e.g. 12000 Hz) to TruSDX TX rate (11520 Hz)
    static func downsample(_ samples: [Float], from sourceSR: Double, to targetSR: Double = txSampleRate) -> [Float] {
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
