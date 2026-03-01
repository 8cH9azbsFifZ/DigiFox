/// Winlink B2F/FBB Nachrichtenaustausch-Protokoll.
///
/// Implementiert das B2F (Binary-2-FBB) Protokoll für den Austausch von
/// Winlink-Nachrichten zwischen Client und RMS-Gateway (oder P2P).
///
/// Protokollablauf:
/// 1. Connect + Login (Callsign + Password Challenge/Response)
/// 2. Proposal Phase — Client schlägt Nachrichten zum Senden vor
/// 3. Accept/Reject — Server akzeptiert oder lehnt Proposals ab
/// 4. Data Transfer — Nachrichten werden LZHUF-komprimiert übertragen
/// 5. Disconnect
///
/// Referenz: https://github.com/la5nta/wl2k-go/tree/master/fbb
/// Referenz: http://www.intangiblesoftware.com/B2F_protocol.pdf

import Foundation

// MARK: - B2F Protocol Constants

/// B2F Protokollkonstanten
enum B2FProtocol {
    /// Protocol version string
    static let version = "FBB"
    /// Secure login prompt prefix
    static let loginPrompt = ";PQ: "
    /// Proposal prefix for message to send
    static let proposalPrefix = "FC"
    /// Proposal acceptance
    static let proposalAccept = "FS"
    /// Proposal rejection flag
    static let proposalReject = "FR"
    /// Proposal defer
    static let proposalDefer = "FD"
    /// Final (no more proposals)
    static let proposalDone = "FF"
    /// No proposals
    static let proposalNone = "FQ"
    /// B2F message type identifier
    static let messageTypePrivate = "P"
    static let messageTypeNTS = "T"
    static let messageTypeBulletin = "B"
    /// Maximum uncompressed message size (120 KB default)
    static let maxMessageSize = 120_000
    /// Line ending
    static let crlf = "\r\n"
    /// SID (System Identifier) string
    static let sid = "[DigiFox-1.0-B2FHIM$]"
}

// MARK: - B2F Message Proposal

/// Nachrichtenvorschlag (Proposal) im B2F-Protokoll
struct B2FProposal: Sendable {
    /// Message type (P=Private, T=NTS, B=Bulletin)
    let messageType: String
    /// Source callsign
    let from: String
    /// Destination (callsign@winlink.org or email)
    let to: String
    /// Message ID (unique, 12 chars max)
    let messageId: String
    /// Uncompressed size in bytes
    let uncompressedSize: Int
    /// Compressed size in bytes
    let compressedSize: Int
    /// Offset for partial delivery (0 = full message)
    let offset: Int

    /// Formatiert als B2F-Proposal-Zeile: "FC EM CALL DEST MID SIZE CSIZE OFFSET"
    var proposalLine: String {
        "\(B2FProtocol.proposalPrefix) \(messageType) \(from) \(to) \(messageId) \(uncompressedSize) \(compressedSize) \(offset)"
    }
}

/// Antwort auf einen Proposal
enum ProposalResponse: Character, Sendable {
    case accept = "+"    // Nachricht senden
    case reject = "-"    // Nachricht ablehnen
    case `defer` = "="   // Nachricht später
    case skip = "!"      // Überspringen (Fehler)
    case hold = "H"      // Halten
}

// MARK: - B2F Session Handler

/// Verwaltet eine B2F-Protokollsitzung.
///
/// Kann sowohl über ARDOP-ARQ als auch über Telnet verwendet werden.
/// Der Transport-Layer liefert Daten über das `B2FTransport` Protokoll.
protocol B2FTransport: AnyObject, Sendable {
    func sendLine(_ line: String) async throws
    func receiveLine() async throws -> String
    func sendData(_ data: Data) async throws
    func receiveData(count: Int) async throws -> Data
    var isConnected: Bool { get }
}

/// B2F Protokoll-Handler für Winlink-Nachrichtenaustausch.
///
/// Führt den vollständigen B2F-Protokollablauf durch:
/// Login → Proposals → Datenübertragung → Disconnect
final class B2FSession {

    private let transport: B2FTransport
    private let account: WinlinkAccount
    private let mailbox: WinlinkMailbox
    private let lzhuf = LZHUFCodec()

    /// Fortschrittsinformation
    struct Progress: Sendable {
        var phase: String
        var detail: String
        var messagesProposed: Int = 0
        var messagesAccepted: Int = 0
        var messagesSent: Int = 0
        var messagesReceived: Int = 0
        var bytesTransferred: Int = 0
    }

    var onProgress: ((Progress) -> Void)?
    private var progress = Progress(phase: "Initialisierung", detail: "")

    init(transport: B2FTransport, account: WinlinkAccount, mailbox: WinlinkMailbox) {
        self.transport = transport
        self.account = account
        self.mailbox = mailbox
    }

    // MARK: - Main Protocol Flow

    /// Führt eine vollständige B2F-Sitzung durch.
    /// Sendet und empfängt alle ausstehenden Nachrichten.
    func exchange() async throws {
        // 1. Login
        updateProgress(phase: "Anmeldung", detail: "Sende Callsign...")
        try await login()

        // 2. Send our proposals (outgoing messages)
        updateProgress(phase: "Proposals", detail: "Schlage Nachrichten vor...")
        try await sendProposals()

        // 3. Process incoming proposals from remote
        updateProgress(phase: "Empfang", detail: "Prüfe eingehende Nachrichten...")
        try await receiveProposals()

        // 4. Signal done
        try await transport.sendLine(B2FProtocol.proposalDone)

        updateProgress(phase: "Abgeschlossen", detail: "Sitzung beendet")
    }

    // MARK: - Login Phase

    private func login() async throws {
        // Send SID
        try await transport.sendLine(B2FSession.formatSID())

        // Read remote SID
        let remoteSID = try await transport.receiveLine()
        guard remoteSID.hasPrefix("[") else {
            throw WinlinkError.protocolError("Ungültiger SID: \(remoteSID)")
        }

        // Handle secure login challenge
        let challengeLine = try await transport.receiveLine()
        if challengeLine.hasPrefix(B2FProtocol.loginPrompt) {
            let challenge = String(challengeLine.dropFirst(B2FProtocol.loginPrompt.count))
            let response = WinlinkAccountManager.shared.challengeResponse(
                challenge: challenge,
                password: account.password
            )
            try await transport.sendLine(";PR: \(response)")
        }

        // Confirm login
        let loginResponse = try await transport.receiveLine()
        guard !loginResponse.contains("*** Denied") else {
            throw WinlinkError.authenticationFailed
        }
    }

    // MARK: - Proposal Phase (Outgoing)

    private func sendProposals() async throws {
        let outgoing = mailbox.outboxMessages()
        guard !outgoing.isEmpty else {
            try await transport.sendLine(B2FProtocol.proposalNone)
            return
        }

        for message in outgoing {
            let compressed = compressMessage(message)
            let proposal = B2FProposal(
                messageType: B2FProtocol.messageTypePrivate,
                from: account.callsign.uppercased(),
                to: message.to,
                messageId: message.messageId,
                uncompressedSize: message.rawData.count,
                compressedSize: compressed.count,
                offset: 0
            )
            try await transport.sendLine(proposal.proposalLine)
            progress.messagesProposed += 1
            updateProgress(phase: "Proposals", detail: "\(progress.messagesProposed) Nachrichten vorgeschlagen")
        }

        try await transport.sendLine(B2FProtocol.proposalDone)

        // Read responses
        let responseLine = try await transport.receiveLine()
        guard responseLine.hasPrefix(B2FProtocol.proposalAccept) else {
            return // All rejected or deferred
        }

        let responses = String(responseLine.dropFirst(B2FProtocol.proposalAccept.count + 1))
        for (i, response) in responses.enumerated() {
            guard i < outgoing.count else { break }
            if response == ProposalResponse.accept.rawValue {
                let compressed = compressMessage(outgoing[i])
                try await sendCompressedMessage(compressed)
                progress.messagesSent += 1
                progress.bytesTransferred += compressed.count
                mailbox.markSent(messageId: outgoing[i].messageId)
                updateProgress(phase: "Sende", detail: "Nachricht \(progress.messagesSent) gesendet")
            }
        }
    }

    // MARK: - Proposal Phase (Incoming)

    private func receiveProposals() async throws {
        while true {
            let line = try await transport.receiveLine()

            if line.hasPrefix(B2FProtocol.proposalDone) || line.hasPrefix(B2FProtocol.proposalNone) {
                break
            }

            if line.hasPrefix(B2FProtocol.proposalPrefix) {
                let proposal = try parseProposal(line)

                // Check if we already have this message
                if mailbox.hasMessage(id: proposal.messageId) {
                    try await transport.sendLine("\(B2FProtocol.proposalAccept) \(ProposalResponse.reject.rawValue)")
                } else {
                    try await transport.sendLine("\(B2FProtocol.proposalAccept) \(ProposalResponse.accept.rawValue)")

                    // Receive compressed data
                    let compressedData = try await transport.receiveData(count: proposal.compressedSize)
                    let decompressed = lzhuf.decompress(compressedData)

                    // Parse and store message
                    if let message = parseReceivedMessage(data: decompressed, proposal: proposal) {
                        mailbox.storeInbox(message: message)
                        progress.messagesReceived += 1
                        progress.bytesTransferred += compressedData.count
                        updateProgress(phase: "Empfang", detail: "\(progress.messagesReceived) Nachrichten empfangen")
                    }
                }
            }
        }
    }

    // MARK: - Message Encoding/Decoding

    private func compressMessage(_ message: WinlinkMessage) -> Data {
        return lzhuf.compress(message.rawData)
    }

    private func sendCompressedMessage(_ data: Data) async throws {
        // B2F sends data with checksum
        var payload = data
        // Append 2-byte checksum (sum of all bytes mod 65536)
        let checksum = data.reduce(0) { (sum: UInt32, byte: UInt8) in sum &+ UInt32(byte) }
        payload.append(UInt8(checksum & 0xFF))
        payload.append(UInt8((checksum >> 8) & 0xFF))
        try await transport.sendData(payload)
    }

    private func parseProposal(_ line: String) throws -> B2FProposal {
        let parts = line.split(separator: " ")
        guard parts.count >= 7 else {
            throw WinlinkError.protocolError("Ungültiger Proposal: \(line)")
        }
        return B2FProposal(
            messageType: String(parts[1]),
            from: String(parts[2]),
            to: String(parts[3]),
            messageId: String(parts[4]),
            uncompressedSize: Int(parts[5]) ?? 0,
            compressedSize: Int(parts[6]) ?? 0,
            offset: parts.count > 7 ? (Int(parts[7]) ?? 0) : 0
        )
    }

    private func parseReceivedMessage(data: Data, proposal: B2FProposal) -> WinlinkMessage? {
        guard let body = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) else {
            return nil
        }

        // Parse MIME-like headers
        var headers: [String: String] = [:]
        var messageBody = ""
        let lines = body.components(separatedBy: "\r\n")
        var inHeaders = true

        for line in lines {
            if inHeaders {
                if line.isEmpty {
                    inHeaders = false
                    continue
                }
                if let colonIdx = line.firstIndex(of: ":") {
                    let key = String(line[..<colonIdx]).trimmingCharacters(in: .whitespaces)
                    let value = String(line[line.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
                    headers[key] = value
                }
            } else {
                messageBody += line + "\n"
            }
        }

        return WinlinkMessage(
            messageId: proposal.messageId,
            from: headers["From"] ?? proposal.from,
            to: headers["To"] ?? proposal.to,
            subject: headers["Subject"] ?? "(Kein Betreff)",
            body: messageBody.trimmingCharacters(in: .whitespacesAndNewlines),
            date: Date(),
            mimeType: headers["Content-Type"] ?? "text/plain",
            folder: .inbox,
            attachments: [],
            isRead: false,
            rawData: data
        )
    }

    // MARK: - Helpers

    private static func formatSID() -> String {
        return B2FProtocol.sid
    }

    private func updateProgress(phase: String, detail: String) {
        progress.phase = phase
        progress.detail = detail
        onProgress?(progress)
    }
}
