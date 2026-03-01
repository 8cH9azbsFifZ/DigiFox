import Foundation
import AVFoundation
import Accelerate
import Combine

class AudioEngine: ObservableObject {
    @Published var isRunning = false
    @Published var isTransmitting = false
    @Published var spectrumData = [Float]()
    @Published var inputLevel: Float = 0
    @Published var usbAudioConnected = false
    /// Effective sample rate of audio in the buffer (always 12 kHz after resampling)
    @Published var effectiveSampleRate: Double = 12000
    /// Actual hardware input sample rate (for logging only)
    @Published var hardwareSampleRate: Double = 12000

    private var engine = AVAudioEngine()
    private let fftProcessor = FFTProcessor(size: 2048)
    private var audioBuffer = [Float]()
    private let bufferLock = NSLock()
    private var routeChangeObserver: NSObjectProtocol?
    private var externalFFTBuffer = [Float]()  // accumulator for external (TruSDX) samples
    /// Actual input sample rate (set from audio tap or external feed, used for resampling)
    private var inputRate: Double = 12000

    /// Resample audio from any source rate to 12 kHz using Accelerate (vDSP_vlint).
    /// Works for both upsampling (e.g. TruSDX 7825→12000) and downsampling (e.g. USB 48000→12000).
    private static func resampleTo12kHz(_ input: [Float], from srcRate: Double) -> [Float] {
        guard !input.isEmpty else { return [] }
        let ratio = srcRate / 12000.0
        if abs(ratio - 1.0) < 0.01 { return input }
        let outputCount = Int(Double(input.count) / ratio)
        guard outputCount > 1 else { return input }

        var positions = [Float](repeating: 0, count: outputCount)
        var start: Float = 0
        var step = Float(ratio)
        vDSP_vramp(&start, &step, &positions, 1, vDSP_Length(outputCount))

        var maxPos = Float(input.count - 1)
        var zero: Float = 0
        vDSP_vclip(positions, 1, &zero, &maxPos, &positions, 1, vDSP_Length(outputCount))

        var output = [Float](repeating: 0, count: outputCount)
        vDSP_vlint(input, positions, 1, &output, 1, vDSP_Length(outputCount), vDSP_Length(input.count))
        return output
    }
    private var monitorPlayer: AVAudioPlayerNode?

    var onSpectrumUpdate: (([Float]) -> Void)?

    init() {
        setupRouteChangeNotification()
        updateUSBStatus()
    }

    deinit {
        if let observer = routeChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - USB Audio Detection

    /// Check if a USB audio device (e.g. Digirig) is connected
    func updateUSBStatus() {
        let session = AVAudioSession.sharedInstance()
        let hasUSB = session.currentRoute.outputs.contains { $0.portType == .usbAudio }
            || session.currentRoute.inputs.contains { $0.portType == .usbAudio }
            || (session.availableInputs ?? []).contains { $0.portType == .usbAudio }
        DispatchQueue.main.async { self.usbAudioConnected = hasUSB }
    }

    /// Get names of connected USB audio devices
    func getUSBAudioDevices() -> [(name: String, direction: String)] {
        let session = AVAudioSession.sharedInstance()
        var devices: [(String, String)] = []
        for input in session.availableInputs ?? [] where input.portType == .usbAudio {
            devices.append((input.portName, "input"))
        }
        for output in session.currentRoute.outputs where output.portType == .usbAudio {
            devices.append((output.portName, "output"))
        }
        return devices
    }

    private func setupRouteChangeNotification() {
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            self.updateUSBStatus()

            guard let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let routeReason = AVAudioSession.RouteChangeReason(rawValue: reason) else { return }

            switch routeReason {
            case .newDeviceAvailable:
                Log.d("Audio", "Route change: new device available — restarting engine")
                if self.isRunning { self.stop(); self.start() }
            case .oldDeviceUnavailable:
                Log.d("Audio", "Route change: device removed — restarting engine")
                if self.isRunning { self.stop(); self.start() }
            default: break
            }
        }
    }

    func start() {
        guard !isRunning else { return }
        Log.d("Audio", "Starting audio engine")
        do {
            let session = AVAudioSession.sharedInstance()

            // Stop any existing engine and deactivate session for clean route switch
            engine.stop()
            try? session.setActive(false, options: .notifyOthersOnDeactivation)

            // Log ALL available inputs for debugging
            let allInputs = session.availableInputs ?? []
            Log.d("Audio", "Available inputs (\(allInputs.count)):")
            for input in allInputs {
                Log.d("Audio", "  • '\(input.portName)' type=\(input.portType.rawValue) uid=\(input.uid)")
            }

            // Find USB audio device — check portType first, then fallback to name matching
            let usbInput = allInputs.first(where: { $0.portType == .usbAudio })
                ?? allInputs.first(where: {
                    let name = $0.portName.lowercased()
                    return name.contains("usb") || name.contains("digirig") || name.contains("cm108")
                })

            let hasUSB = usbInput != nil
            let catOptions: AVAudioSession.CategoryOptions = hasUSB ? [] : [.defaultToSpeaker]
            try session.setCategory(.playAndRecord, mode: .measurement, options: catOptions)

            // Set preferred input BEFORE activating the session
            if let usbInput = usbInput {
                try session.setPreferredInput(usbInput)
                Log.d("Audio", "✅ USB preferred input set: '\(usbInput.portName)' (type=\(usbInput.portType.rawValue))")
            } else {
                Log.d("Audio", "⚠️ No USB audio device found — using built-in mic/speaker")
            }

            try session.setPreferredSampleRate(12000.0)
            try session.setActive(true)

            // Verify route after activation — retry if USB didn't take
            if let usbInput = usbInput {
                let activeInput = session.currentRoute.inputs.first
                if activeInput?.uid != usbInput.uid {
                    Log.d("Audio", "⚠️ USB route didn't take (got '\(activeInput?.portName ?? "none")'), retrying...")
                    try session.setPreferredInput(usbInput)
                }
            }

            // Log actual active route
            let inputs = session.currentRoute.inputs.map { "\($0.portName) (\($0.portType.rawValue))" }
            let outputs = session.currentRoute.outputs.map { "\($0.portName) (\($0.portType.rawValue))" }
            Log.d("Audio", "Active route — IN: \(inputs.joined(separator: ", ")) | OUT: \(outputs.joined(separator: ", "))")
            Log.d("Audio", "Session sampleRate=\(session.sampleRate)")

            updateUSBStatus()

            // Create fresh engine to pick up the new route
            engine = AVAudioEngine()

            let inputNode = engine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            guard format.sampleRate > 0 else {
                Log.d("Audio", "No valid audio format available")
                return
            }
            let actualRate = format.sampleRate
            Log.d("Audio", "Engine input: sampleRate=\(actualRate), ch=\(format.channelCount)")
            inputRate = actualRate
            DispatchQueue.main.async { self.hardwareSampleRate = actualRate }
            inputNode.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
                self?.processInput(buffer)
            }
            try engine.start()
            DispatchQueue.main.async { self.isRunning = true }
            Log.d("Audio", "✅ Audio engine running (USB=\(hasUSB))")
        } catch {
            Log.d("Audio-ERROR", "\(error)")
        }
    }

    /// Select USB audio input if available (e.g. Digirig CM108B).
    /// On iOS, setting preferred input to USB also routes output to the same USB device.
    private func selectUSBAudioInput() {
        let session = AVAudioSession.sharedInstance()
        if let usbInput = (session.availableInputs ?? []).first(where: { $0.portType == .usbAudio }) {
            do {
                try session.setPreferredInput(usbInput)
                Log.d("Audio", "USB audio routed (in+out): \(usbInput.portName)")
            } catch {
                Log.d("Audio", "Failed to select USB input: \(error)")
            }
        }
    }

    func stop() {
        Log.d("Audio", "Stopping audio engine")
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        DispatchQueue.main.async { self.isRunning = false; self.isTransmitting = false }
    }

    func transmit(samples: [Float], completion: (() -> Void)? = nil) {
        guard !samples.isEmpty else {
            completion?()
            return
        }

        // Ensure engine is running for playback
        if !engine.isRunning {
            do {
                let session = AVAudioSession.sharedInstance()
                let hasUSB = (session.availableInputs ?? []).contains { $0.portType == .usbAudio }
                let options: AVAudioSession.CategoryOptions = hasUSB ? [] : [.defaultToSpeaker]
                try session.setCategory(.playAndRecord, mode: .measurement, options: options)
                selectUSBAudioInput()
                try session.setActive(true)
                // Connect a dummy player to mainMixerNode before starting
                // to ensure at least one output node exists
                let _ = engine.mainMixerNode
                try engine.start()
                Log.d("Audio", "transmit: engine started in playback mode")
            } catch {
                Log.d("Audio", "transmit start error: \(error)")
                completion?()
                return
            }
        }

        DispatchQueue.main.async { self.isTransmitting = true }

        // Use the engine's output format for the player connection
        let mixerFormat = engine.mainMixerNode.outputFormat(forBus: 0)
        let outputRate = mixerFormat.sampleRate > 0 ? mixerFormat.sampleRate : 12000.0
        Log.d("Audio", "transmit: \(samples.count) samples at 12kHz, mixer at \(outputRate)Hz")

        // Resample TX audio from 12 kHz to engine output rate if needed
        let txSamples: [Float]
        if abs(outputRate - 12000.0) > 1.0 {
            let ratio = outputRate / 12000.0
            let outCount = Int(Double(samples.count) * ratio)
            var positions = [Float](repeating: 0, count: outCount)
            var start: Float = 0
            var step = Float(1.0 / ratio)
            vDSP_vramp(&start, &step, &positions, 1, vDSP_Length(outCount))
            var maxPos = Float(samples.count - 1)
            var zero: Float = 0
            vDSP_vclip(positions, 1, &zero, &maxPos, &positions, 1, vDSP_Length(outCount))
            var resampled = [Float](repeating: 0, count: outCount)
            vDSP_vlint(samples, positions, 1, &resampled, 1, vDSP_Length(outCount), vDSP_Length(samples.count))
            txSamples = resampled
        } else {
            txSamples = samples
        }

        guard let format = AVAudioFormat(standardFormatWithSampleRate: outputRate, channels: 1) else {
            DispatchQueue.main.async { self.isTransmitting = false }
            completion?()
            return
        }
        let count = AVAudioFrameCount(txSamples.count)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else {
            DispatchQueue.main.async { self.isTransmitting = false }
            completion?()
            return
        }
        buffer.frameLength = count
        if let cd = buffer.floatChannelData?[0] {
            txSamples.withUnsafeBufferPointer { src in
                cd.update(from: src.baseAddress!, count: txSamples.count)
            }
        }

        let player = AVAudioPlayerNode()
        monitorPlayer = player
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        player.scheduleBuffer(buffer) { [weak self] in
            DispatchQueue.main.async {
                self?.isTransmitting = false
                self?.monitorPlayer = nil
                self?.engine.detach(player)
                completion?()
            }
        }
        player.play()
    }

    /// Stop monitor playback immediately (TX Halt)
    func stopPlayback() {
        if let player = monitorPlayer {
            Log.d("Audio", "stopPlayback: stopping monitor player")
            player.stop()
            engine.detach(player)
            monitorPlayer = nil
        }
    }

    private func processInput(_ buffer: AVAudioPCMBuffer) {
        guard let cd = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)
        var raw = [Float](repeating: 0, count: n)
        for i in 0..<n { raw[i] = cd[i] }

        // Resample to 12 kHz if hardware rate differs (e.g. USB at 48kHz)
        let samples = Self.resampleTo12kHz(raw, from: inputRate)

        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(samples.count))
        let spectrum = fftProcessor.magnitudeSpectrum(samples)

        DispatchQueue.main.async { self.inputLevel = rms; self.spectrumData = spectrum }
        onSpectrumUpdate?(spectrum)

        bufferLock.lock()
        audioBuffer.append(contentsOf: samples)
        let maxBuf = Int(12000.0 * 30)
        if audioBuffer.count > maxBuf { audioBuffer.removeFirst(audioBuffer.count - maxBuf) }
        bufferLock.unlock()
    }

    func getBufferedSamples() -> [Float] {
        bufferLock.lock(); defer { bufferLock.unlock() }
        return audioBuffer
    }

    func clearBuffer() {
        bufferLock.lock(); audioBuffer.removeAll(); bufferLock.unlock()
    }

    /// Feed samples from an external source (e.g. TruSDX serial audio) into the buffer
    func feedExternalSamples(_ samples: [Float], sampleRate: Double) {
        inputRate = sampleRate
        DispatchQueue.main.async {
            if self.hardwareSampleRate != sampleRate {
                Log.d("Audio", "external hardware sampleRate changed: \(self.hardwareSampleRate) → \(sampleRate)")
                self.hardwareSampleRate = sampleRate
            }
        }
        processInput_external(samples, srcRate: sampleRate)
    }

    private func processInput_external(_ raw: [Float], srcRate: Double) {
        guard !raw.isEmpty else { return }

        // Resample to 12 kHz (e.g. TruSDX 7825 Hz → 12000 Hz)
        let samples = Self.resampleTo12kHz(raw, from: srcRate)

        let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
        DispatchQueue.main.async { self.inputLevel = rms }

        // Accumulate resampled samples for FFT
        externalFFTBuffer.append(contentsOf: samples)
        while externalFFTBuffer.count >= fftProcessor.size {
            let chunk = Array(externalFFTBuffer.prefix(fftProcessor.size))
            externalFFTBuffer.removeFirst(fftProcessor.size)
            let spectrum = fftProcessor.magnitudeSpectrum(chunk)
            if !spectrum.isEmpty {
                DispatchQueue.main.async {
                    self.spectrumData = spectrum
                    self.onSpectrumUpdate?(spectrum)
                }
            }
        }

        bufferLock.lock()
        audioBuffer.append(contentsOf: samples)
        let maxBuf = Int(12000.0 * 30)
        if audioBuffer.count > maxBuf { audioBuffer.removeFirst(audioBuffer.count - maxBuf) }
        bufferLock.unlock()
    }
}
