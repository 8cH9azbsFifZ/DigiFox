import AVFoundation
import Combine

/// Manages USB Audio Class device I/O for digital mode audio.
/// The (tr)uSDX presents as a standard USB Audio device when connected via USB-C.
class USBAudioManager: ObservableObject {
    
    enum AudioState: Equatable {
        case idle
        case monitoring
        case transmitting
        case error(String)
    }
    
    @Published var audioState: AudioState = .idle
    @Published var inputLevel: Float = 0
    @Published var outputLevel: Float = 0
    @Published var usbAudioDeviceConnected: Bool = false
    
    private let audioEngine = AVAudioEngine()
    private var inputNode: AVAudioInputNode { audioEngine.inputNode }
    private var outputNode: AVAudioOutputNode { audioEngine.outputNode }
    private var playerNode = AVAudioPlayerNode()
    
    /// Buffer for incoming audio samples (RX from radio)
    var onAudioReceived: (([Float]) -> Void)?
    
    /// Current audio format from USB device
    var inputFormat: AVAudioFormat? {
        audioEngine.inputNode.inputFormat(forBus: 0)
    }
    
    init() {
        setupNotifications()
    }
    
    deinit {
        stop()
    }
    
    // MARK: - Audio Session Configuration
    
    /// Configure audio session for USB audio device
    func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        
        try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetooth])
        try session.setPreferredSampleRate(48000)
        try session.setPreferredIOBufferDuration(0.01) // 10ms buffer
        try session.setActive(true)
        
        checkForUSBAudioDevice()
    }
    
    /// Start monitoring audio from the USB audio device (RX)
    func startMonitoring() throws {
        guard !audioEngine.isRunning else { return }
        
        try configureAudioSession()
        
        let format = inputNode.inputFormat(forBus: 0)
        
        // Install tap on input to capture RX audio
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.processInputBuffer(buffer)
        }
        
        audioEngine.attach(playerNode)
        let outputFormat = audioEngine.outputNode.inputFormat(forBus: 0)
        audioEngine.connect(playerNode, to: audioEngine.outputNode, format: outputFormat)
        
        try audioEngine.start()
        audioState = .monitoring
    }
    
    /// Play audio samples through the USB audio device (TX)
    func playAudio(samples: [Float], sampleRate: Double = 48000) {
        guard audioEngine.isRunning else { return }
        
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let frameCount = AVAudioFrameCount(samples.count)
        
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
        buffer.frameLength = frameCount
        
        if let channelData = buffer.floatChannelData {
            samples.withUnsafeBufferPointer { ptr in
                channelData[0].initialize(from: ptr.baseAddress!, count: samples.count)
            }
        }
        
        playerNode.scheduleBuffer(buffer, completionHandler: nil)
        if !playerNode.isPlaying {
            playerNode.play()
        }
        
        audioState = .transmitting
    }
    
    /// Stop all audio processing
    func stop() {
        inputNode.removeTap(onBus: 0)
        playerNode.stop()
        audioEngine.stop()
        audioState = .idle
    }
    
    // MARK: - Private
    
    private func processInputBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        
        let frames = Int(buffer.frameLength)
        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: frames))
        
        // Calculate RMS level
        let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(frames))
        DispatchQueue.main.async {
            self.inputLevel = rms
        }
        
        onAudioReceived?(samples)
    }
    
    private func checkForUSBAudioDevice() {
        let session = AVAudioSession.sharedInstance()
        let route = session.currentRoute
        
        let hasUSBInput = route.inputs.contains { port in
            port.portType == .usbAudio
        }
        let hasUSBOutput = route.outputs.contains { port in
            port.portType == .usbAudio
        }
        
        usbAudioDeviceConnected = hasUSBInput || hasUSBOutput
    }
    
    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
    }
    
    @objc private func handleRouteChange(_ notification: Notification) {
        checkForUSBAudioDevice()
        
        guard let info = notification.userInfo,
              let reasonValue = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
            return
        }
        
        switch reason {
        case .newDeviceAvailable:
            if usbAudioDeviceConnected {
                try? startMonitoring()
            }
        case .oldDeviceUnavailable:
            if !usbAudioDeviceConnected {
                stop()
            }
        default:
            break
        }
    }
}
