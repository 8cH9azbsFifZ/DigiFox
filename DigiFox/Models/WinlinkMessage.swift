/// Winlink-Nachrichtenmodell und Mailbox-Verwaltung.
///
/// Lokale Speicherung und Verwaltung von Winlink-Nachrichten.
/// Nachrichten werden als JSON-Dateien im App-Dokumentenverzeichnis gespeichert.
///
/// Referenz: https://github.com/la5nta/pat (mailbox package)

import Foundation

// MARK: - Message Model

/// Ordner für Winlink-Nachrichten
enum WinlinkFolder: String, Codable, CaseIterable, Sendable {
    case inbox = "Posteingang"
    case outbox = "Postausgang"
    case sent = "Gesendet"
    case archive = "Archiv"

    var systemImage: String {
        switch self {
        case .inbox: return "tray.and.arrow.down"
        case .outbox: return "tray.and.arrow.up"
        case .sent: return "paperplane"
        case .archive: return "archivebox"
        }
    }
}

/// Eine Winlink-E-Mail-Nachricht
struct WinlinkMessage: Identifiable, Codable, Sendable {
    /// Eindeutige Nachrichten-ID (max 12 Zeichen, B2F-kompatibel)
    let messageId: String
    /// Absender (Callsign oder E-Mail)
    let from: String
    /// Empfänger (Callsign@winlink.org oder E-Mail)
    let to: String
    /// CC-Empfänger
    var cc: String?
    /// Betreff
    let subject: String
    /// Nachrichtentext
    let body: String
    /// Zeitstempel
    let date: Date
    /// MIME-Type
    var mimeType: String = "text/plain"
    /// Ordner
    var folder: WinlinkFolder
    /// Anhänge
    var attachments: [WinlinkAttachment]
    /// Gelesen-Status
    var isRead: Bool
    /// Rohdaten (für B2F-Übertragung)
    var rawData: Data

    var id: String { messageId }

    /// Formatiert die Nachricht als MIME-Daten für B2F-Übertragung
    var mimeData: Data {
        var mime = "Mid: \(messageId)\r\n"
        mime += "From: \(from)\r\n"
        mime += "To: \(to)\r\n"
        if let cc = cc, !cc.isEmpty {
            mime += "Cc: \(cc)\r\n"
        }
        mime += "Subject: \(subject)\r\n"
        mime += "Date: \(ISO8601DateFormatter().string(from: date))\r\n"
        mime += "Content-Type: \(mimeType)\r\n"
        mime += "\r\n"
        mime += body
        return Data(mime.utf8)
    }

    /// Erzeugt eine neue Nachrichten-ID (12 Zeichen, alphanumerisch)
    static func generateId(callsign: String) -> String {
        let chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        let random = String((0..<6).map { _ in chars.randomElement()! })
        let prefix = String(callsign.prefix(4)).uppercased()
        return "\(prefix)\(random)"
    }
}

/// Nachrichtenanhang
struct WinlinkAttachment: Identifiable, Codable, Sendable {
    let id: String
    let filename: String
    let mimeType: String
    let data: Data

    var sizeFormatted: String {
        ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
    }

    init(filename: String, mimeType: String, data: Data) {
        self.id = UUID().uuidString
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
    }
}

// MARK: - Mailbox Storage

/// Lokale Winlink-Mailbox.
///
/// Speichert Nachrichten als JSON-Dateien im App-Dokumentenverzeichnis.
/// Thread-sicher über serielle DispatchQueue.
final class WinlinkMailbox {

    private let storageQueue = DispatchQueue(label: "com.digifox.winlink.mailbox")
    private let mailboxDir: URL

    /// Singleton-Instanz
    static let shared = WinlinkMailbox()

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        mailboxDir = docs.appendingPathComponent("WinlinkMailbox", isDirectory: true)

        // Ordner anlegen
        for folder in WinlinkFolder.allCases {
            let folderDir = mailboxDir.appendingPathComponent(folder.rawValue, isDirectory: true)
            try? FileManager.default.createDirectory(at: folderDir, withIntermediateDirectories: true)
        }
    }

    // MARK: - CRUD Operations

    /// Alle Nachrichten in einem Ordner abrufen.
    func messages(in folder: WinlinkFolder) -> [WinlinkMessage] {
        return storageQueue.sync {
            loadMessages(folder: folder)
        }
    }

    /// Nachrichten im Postausgang (zum Senden bereit).
    func outboxMessages() -> [WinlinkMessage] {
        return messages(in: .outbox)
    }

    /// Anzahl ungelesener Nachrichten im Posteingang.
    func unreadCount() -> Int {
        return messages(in: .inbox).filter { !$0.isRead }.count
    }

    /// Nachricht im Posteingang speichern.
    func storeInbox(message: WinlinkMessage) {
        var msg = message
        msg.folder = .inbox
        saveMessage(msg)
    }

    /// Nachricht zum Senden in den Postausgang legen.
    func storeOutbox(message: WinlinkMessage) {
        var msg = message
        msg.folder = .outbox
        saveMessage(msg)
    }

    /// Nachricht als gesendet markieren (Postausgang → Gesendet).
    func markSent(messageId: String) {
        storageQueue.sync {
            if var msg = loadMessage(id: messageId, folder: .outbox) {
                deleteMessage(id: messageId, folder: .outbox)
                msg.folder = .sent
                saveMessageSync(msg)
            }
        }
    }

    /// Nachricht als gelesen markieren.
    func markRead(messageId: String) {
        storageQueue.sync {
            if var msg = loadMessage(id: messageId, folder: .inbox) {
                msg.isRead = true
                saveMessageSync(msg)
            }
        }
    }

    /// Nachricht in Archiv verschieben.
    func archive(messageId: String, from folder: WinlinkFolder) {
        storageQueue.sync {
            if var msg = loadMessage(id: messageId, folder: folder) {
                deleteMessage(id: messageId, folder: folder)
                msg.folder = .archive
                saveMessageSync(msg)
            }
        }
    }

    /// Nachricht löschen.
    func delete(messageId: String, folder: WinlinkFolder) {
        storageQueue.sync {
            deleteMessage(id: messageId, folder: folder)
        }
    }

    /// Prüft ob eine Nachricht bereits existiert (in irgendeinem Ordner).
    func hasMessage(id: String) -> Bool {
        return storageQueue.sync {
            WinlinkFolder.allCases.contains { folder in
                loadMessage(id: id, folder: folder) != nil
            }
        }
    }

    // MARK: - File Operations

    private func folderURL(_ folder: WinlinkFolder) -> URL {
        mailboxDir.appendingPathComponent(folder.rawValue, isDirectory: true)
    }

    private func messageURL(id: String, folder: WinlinkFolder) -> URL {
        folderURL(folder).appendingPathComponent("\(id).json")
    }

    private func saveMessage(_ message: WinlinkMessage) {
        storageQueue.sync {
            saveMessageSync(message)
        }
    }

    private func saveMessageSync(_ message: WinlinkMessage) {
        let url = messageURL(id: message.messageId, folder: message.folder)
        if let data = try? JSONEncoder().encode(message) {
            try? data.write(to: url)
        }
    }

    private func loadMessages(folder: WinlinkFolder) -> [WinlinkMessage] {
        let dir = folderURL(folder)
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }

        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> WinlinkMessage? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(WinlinkMessage.self, from: data)
            }
            .sorted { $0.date > $1.date }
    }

    private func loadMessage(id: String, folder: WinlinkFolder) -> WinlinkMessage? {
        let url = messageURL(id: id, folder: folder)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WinlinkMessage.self, from: data)
    }

    private func deleteMessage(id: String, folder: WinlinkFolder) {
        let url = messageURL(id: id, folder: folder)
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Statistics

    /// Mailbox-Statistik
    struct MailboxStats {
        let inboxCount: Int
        let unreadCount: Int
        let outboxCount: Int
        let sentCount: Int
        let archiveCount: Int
    }

    func getStats() -> MailboxStats {
        MailboxStats(
            inboxCount: messages(in: .inbox).count,
            unreadCount: unreadCount(),
            outboxCount: messages(in: .outbox).count,
            sentCount: messages(in: .sent).count,
            archiveCount: messages(in: .archive).count
        )
    }
}
