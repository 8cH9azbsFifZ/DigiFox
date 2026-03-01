import Foundation
import Combine

/// Central log manager that captures all debug output for the in-app log view.
/// Thread-safe singleton — call `Log.d(tag, message)` from anywhere.
final class LogManager: ObservableObject {
    static let shared = LogManager()

    struct Entry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let tag: String
        let message: String

        var formatted: String {
            let tf = Self.formatter
            return "\(tf.string(from: timestamp)) [\(tag)] \(message)"
        }

        private static let formatter: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss.SSS"
            return f
        }()
    }

    @Published private(set) var entries = [Entry]()
    private let lock = NSLock()
    private let maxEntries = 2000

    private init() {}

    func log(_ tag: String, _ message: String) {
        let entry = Entry(timestamp: Date(), tag: tag, message: message)
        DispatchQueue.main.async {
            self.entries.append(entry)
            if self.entries.count > self.maxEntries {
                self.entries.removeFirst(self.entries.count - self.maxEntries)
            }
        }
    }

    func clear() {
        DispatchQueue.main.async {
            self.entries.removeAll()
        }
    }
}

/// Shorthand logging — use `Log.d("TAG", "message")` everywhere.
enum Log {
    static func d(_ tag: String, _ message: String) {
        LogManager.shared.log(tag, message)
    }
}
