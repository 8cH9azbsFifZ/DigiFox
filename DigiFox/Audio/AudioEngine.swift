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

    private var engine = AVAudioEngine()
    private let fftProcessor = FFTProcessor(size: 2048)
    private var audioBuffer = [Float]()
    private let bufferLock = NSLock()
    private var routeChangeObserver: NSObjectProtocol?

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
                // USB device plugged in — restart to pick it up
                if self.isRunning { self.stop(); self.start() }
            case .oldDeviceUnavailable:
                // USB device unplugged
                if self.isRunning { self.stop() }
            default: break
            }
        }
    }

    func start() {
        guard !isRunning else { return }
        do {
            let session = AVAudioSession.sharedInstance()

            // Check for USB audio first — if present, don't use defaultToSpeaker
            let hasUSB = (session.availableInputs ?? []).contains { $0.portType == .usbAudio }
            let options: AVAudioSession.CategoryOptions = hasUSB ? [] : [.defaultToSpeaker]
            try session.setCategory(.playAndRecord, mode: .measurement, options: options)
            try session.setPreferredSampleRate(12000.0)
            try session.setActive(true)

            // Route input AND output to USB audio device (Digirig CM108B)
            selectUSBAudioInput()

            updateUSBStatus()

            let inputNode = engine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            guard format.sampleRate > 0 else {
                print("AudioEngine: No valid audio format available")
                return
            }
            inputNode.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
                self?.processInput(buffer)
            }
            try engine.start()
            DispatchQueue.main.async { self.isRunning = true }
        } catch {
            print("AudioEngine error: \(error)")
        }
    }

    /// Select USB audio input if available (e.g. Digirig CM108B).
    /// On iOS, setting preferred input to USB also routes output to the same USB device.
    private func selectUSBAudioInput() {
        let session = AVAudioSession.sharedInstance()
        if let usbInput = (session.availableInputs ?? []).first(where: { $0.portType == .usbAudio }) {
            do {
                try session.setPreferredInput(usbInput)
                print("AudioEngine: USB audio routed (in+out): \(usbInput.portName)")
            } catch {
                print("AudioEngine: Failed to select USB input: \(error)")
            }
        } else {
            print("AudioEngine: No USB audio device found, using built-in mic/speaker")
        }
    }

    func stop() {
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
                try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker])
                try session.setActive(true)
                try engine.start()
            } catch {
                print("AudioEngine transmit start error: \(error)")
                completion?()
                return
            }
        }

        DispatchQueue.main.async { self.isTransmitting = true }

        guard let format = AVAudioFormat(standardFormatWithSampleRate: 12000.0, channels: 1) else {
            DispatchQueue.main.async { self.isTransmitting = false }
            completion?()
            return
        }
        let count = AVAudioFrameCount(samples.count)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else {
            DispatchQueue.main.async { self.isTransmitting = false }
            completion?()
            return
        }
        buffer.frameLength = count
        if let cd = buffer.floatChannelData?[0] {
            for i in 0..<samples.count { cd[i] = samples[i] }
        }

        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        player.scheduleBuffer(buffer) { [weak self] in
            DispatchQueue.main.async {
                self?.isTransmitting = false
                self?.engine.detach(player)
                completion?()
            }
        }
        player.play()
    }

    private func processInput(_ buffer: AVAudioPCMBuffer) {
        guard let cd = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)
        var samples = [Float](repeating: 0, count: n)
        for i in 0..<n { samples[i] = cd[i] }

        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(n))
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
}
