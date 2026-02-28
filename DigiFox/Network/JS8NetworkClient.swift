import Foundation
import Network
import Combine

class JS8NetworkClient: ObservableObject {
    @Published var isConnected = false
    @Published var lastError: String?
    @Published var receivedMessages = [JS8APIMessage]()

    private var connection: NWConnection?
    private var receiveBuffer = Data()
    private let bufferLock = NSLock()
    var onMessageReceived: ((JS8APIMessage) -> Void)?

    func connect(host: String, port: Int) {
        disconnect()
        guard port > 0, port <= 65535, let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return }
        let endpoint = NWEndpoint.hostPort(host: .init(host), port: nwPort)
        connection = NWConnection(to: endpoint, using: .tcp)

        connection?.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .ready:
                    self?.isConnected = true; self?.lastError = nil; self?.startReceiving()
                case .failed(let e):
                    self?.isConnected = false; self?.lastError = e.localizedDescription
                case .cancelled:
                    self?.isConnected = false
                default: break
                }
            }
        }
        connection?.start(queue: .global(qos: .userInitiated))
    }

    func disconnect() {
        connection?.cancel(); connection = nil
        DispatchQueue.main.async { self.isConnected = false }
    }

    func send(_ message: JS8APIMessage) {
        guard let conn = connection, isConnected else { return }
        guard var data = try? JSONEncoder().encode(message) else { return }
        data.append(0x0A)
        conn.send(content: data, completion: .contentProcessed { _ in })
    }

    func sendText(_ text: String) { send(JS8APIMessage(type: "TX.SEND_MESSAGE", value: text)) }
    func requestRxText() { send(JS8APIMessage(type: "RX.GET_TEXT", value: "")) }
    func requestStatus() { send(JS8APIMessage(type: "STATION.GET_STATUS", value: "")) }

    private func startReceiving() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            if let data {
                self?.bufferLock.lock()
                self?.receiveBuffer.append(data)
                self?.bufferLock.unlock()
                self?.processBuffer()
            }
            if error != nil || isComplete { self?.disconnect(); return }
            self?.startReceiving()
        }
    }

    private func processBuffer() {
        bufferLock.lock()
        while let idx = receiveBuffer.firstIndex(of: 0x0A) {
            let msgData = receiveBuffer.prefix(upTo: idx)
            receiveBuffer = receiveBuffer.suffix(from: receiveBuffer.index(after: idx))
            bufferLock.unlock()
            if let msg = try? JSONDecoder().decode(JS8APIMessage.self, from: msgData) {
                DispatchQueue.main.async { self.receivedMessages.append(msg); self.onMessageReceived?(msg) }
            }
            bufferLock.lock()
        }
        bufferLock.unlock()
    }
}
