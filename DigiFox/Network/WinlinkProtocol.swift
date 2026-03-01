/// Winlink B2F/FBB message exchange protocol.
///
/// Implements the B2F (Binary-2-FBB) protocol for exchanging
/// Winlink messages between client and RMS gateway (or P2P).
///
/// The protocol flow follows the reference implementation exactly:
///   https://github.com/la5nta/wl2k-go/blob/master/fbb/b2f.go
///
/// Binary data transfer uses SOH/STX/EOT framing:
///   SOH (0x01) + Len + Title + NUL + Offset + NUL    (Header)
///   STX (0x02) + Len + Data (max 125 bytes)           (Data blocks)
///   EOT (0x04) + Checksum                              (Termination)
///
/// Reference: http://www.intangiblesoftware.com/B2F_protocol.pdf

import Foundation

// MARK: - B2F Protocol Constants

/// B2F protocol constants (identical to wl2k-go/fbb)
enum B2FProtocol {
    static let sid = "[DigiFox-1.0-B2FHIM$]"
    static let loginPrompt = ";PQ: "
    static let maxBlockSize = 5
    static let maxMsgLength = 125  // Max chunk size (AX.25 compatible)

    // Framing bytes
    static let chrNUL: UInt8 = 0x00
    static let chrSOH: UInt8 = 0x01
    static let chrSTX: UInt8 = 0x02
    static let chrEOT: UInt8 = 0x04

    // Proposal commands
    static let cmdNoMoreMessages = "FF"
    static let cmdQuit = "FQ"
}

// MARK: - B2F Message Proposal

/// Message proposal in the B2F protocol
struct B2FProposal: Sendable {
    /// Proposal code: 'C' = Wl2k B2 extended, 'B' = FBB
    let code: Character
    /// Message type (EM=email, P=private)
    let msgType: String
    /// Source callsign
    let from: String
    /// Destination
    let to: String
    /// Unique message ID (max 12 chars)
    let messageId: String
    /// Message title/subject
    var title: String = ""
    /// Uncompressed size in bytes
    let uncompressedSize: Int
    /// Compressed size in bytes
    let compressedSize: Int
    /// Offset for resumed transfer
    var offset: Int = 0

    /// Compressed data (filled during send/receive)
    var compressedData: Data = Data()

    /// Proposal answer from remote
    var answer: ProposalAnswer = .defer_

    /// Formatted as B2F proposal line: "FC EM MID SIZE CSIZE 0"
    var proposalLine: String {
        "F\(code) \(msgType) \(messageId) \(uncompressedSize) \(compressedSize) 0"
    }
}

/// Response to a proposal (compatible with wl2k-go)
enum ProposalAnswer: Character, Sendable {
    case accept = "+"
    case reject = "-"
    case defer_ = "="
    case hold = "H"
}

// MARK: - B2F Transport Protocol

/// Transport abstraction for B2F (Telnet or ARDOP).
protocol B2FTransport: AnyObject, Sendable {
    func sendLine(_ line: String) async throws
    func receiveLine() async throws -> String
    func sendData(_ data: Data) async throws
    func receiveData(count: Int) async throws -> Data
    func sendByte(_ byte: UInt8) async throws
    func receiveByte() async throws -> UInt8
    var isConnected: Bool { get }
}

// MARK: - B2F Session Handler

/// B2F Protokoll-Handler — vollständiger Nachrichtenaustausch.
///
/// Implementiert den Ablauf wie in wl2k-go/fbb:
/// 1. SID-Austausch + Challenge/Response Login
/// 2. Outbound Proposals + Compressed Data (SOH/STX/EOT)
/// 3. Inbound Proposals + Compressed Data
/// 4. FF/FQ Terminierung
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
        Log.d("B2F", "Session erstellt für \(account.callsign)")
    }

    // MARK: - Main Protocol Flow

    func exchange() async throws {
        Log.d("B2F", "=== Sitzung Start ===")
        updateProgress(phase: "Anmeldung", detail: "Sende SID...")

        // 1. Login (SID exchange + challenge/response)
        try await login()

        // 2. Send our proposals (outgoing)
        updateProgress(phase: "Senden", detail: "Outbound proposals...")
        let quitSent = try await handleOutbound()

        if !quitSent {
            // 3. Receive proposals (incoming)
            updateProgress(phase: "Empfang", detail: "Inbound proposals...")
            let _ = try await handleInbound()
        }

        Log.d("B2F", "=== Sitzung Ende: sent=\(progress.messagesSent) rcvd=\(progress.messagesReceived) ===")
        updateProgress(phase: "Abgeschlossen", detail: "Sitzung beendet")
    }

    // MARK: - Login Phase

    private func login() async throws {
        // Send our SID
        let ourSID = B2FProtocol.sid
        Log.d("B2F", "TX SID: \(ourSID)")
        try await transport.sendLine(ourSID)

        // Read remote SID
        let remoteSID = try await transport.receiveLine()
        Log.d("B2F", "RX SID: \(remoteSID)")
        guard remoteSID.hasPrefix("[") else {
            throw WinlinkError.protocolError("Ungültiger SID: \(remoteSID)")
        }

        // Handle challenge/response
        let challengeLine = try await transport.receiveLine()
        Log.d("B2F", "RX Challenge: \(challengeLine)")

        if challengeLine.hasPrefix(B2FProtocol.loginPrompt) {
            let challenge = String(challengeLine.dropFirst(B2FProtocol.loginPrompt.count))
            let response = WinlinkAccountManager.shared.challengeResponse(
                challenge: challenge,
                password: account.password
            )
            let responseLine = ";PR: \(response)"
            Log.d("B2F", "TX Response: \(responseLine)")
            try await transport.sendLine(responseLine)
        }

        // Read login confirmation
        let loginResp = try await transport.receiveLine()
        Log.d("B2F", "RX Login: \(loginResp)")
        guard !loginResp.contains("*** Denied") else {
            throw WinlinkError.authenticationFailed
        }
    }

    // MARK: - Outbound (Sending)

    /// Sends outbound proposals and data. Returns whether FQ was sent.
    private func handleOutbound() async throws -> Bool {
        let outbound = mailbox.outboxMessages()

        if outbound.isEmpty {
            // No outgoing messages — send FF or FQ
            let cmd = B2FProtocol.cmdNoMoreMessages  // "FF"
            Log.d("B2F", "TX: \(cmd) (no outgoing messages)")
            try await transport.sendLine(cmd)
            return false
        }

        // Limit to MaxBlockSize proposals per round
        let batch = Array(outbound.prefix(B2FProtocol.maxBlockSize))
        var proposals = [B2FProposal]()
        var checksum: Int64 = 0

        for message in batch {
            let compressed = lzhuf.compress(message.rawData)
            let prop = B2FProposal(
                code: "C",
                msgType: "EM",
                from: account.callsign.uppercased(),
                to: message.to,
                messageId: message.messageId,
                title: message.subject,
                uncompressedSize: message.rawData.count,
                compressedSize: compressed.count,
                compressedData: compressed
            )
            proposals.append(prop)

            let line = prop.proposalLine
            Log.d("B2F", "TX Proposal: \(line)")
            try await transport.sendLine(line)

            // Accumulate proposal checksum (matches wl2k-go)
            for c in line.unicodeScalars {
                checksum += Int64(c.value)
            }
            checksum += Int64(Character("\r").asciiValue ?? 13)

            progress.messagesProposed += 1
        }

        // Send prompt with checksum
        checksum = (-checksum) & 0xFF
        let prompt = String(format: "F> %02X", checksum)
        Log.d("B2F", "TX Prompt: \(prompt)")
        try await transport.sendLine(prompt)

        // Read proposal answer (FS +-=...)
        var reply = ""
        while reply.isEmpty {
            let line = try await transport.receiveLine()
            Log.d("B2F", "RX: \(line)")
            if line.hasPrefix("FS ") {
                reply = line
            } else if line.hasPrefix(";") {
                continue  // Ignore comments
            } else {
                throw WinlinkError.protocolError("Unerwartete Antwort: \(line)")
            }
        }

        // Parse FS response: "FS ++-=" → individual answers
        let answers = String(reply.dropFirst(3))  // Drop "FS "
        for (i, ch) in answers.enumerated() {
            guard i < proposals.count else { break }
            switch ch {
            case "+", "Y", "y":
                proposals[i].answer = .accept
            case "-", "N", "n", "R", "r":
                proposals[i].answer = .reject
            case "=", "L", "l", "H", "h":
                proposals[i].answer = .defer_
            default:
                Log.d("B2F", "Unknown answer '\(ch)' for proposal \(i)")
                proposals[i].answer = .defer_
            }
        }

        // Send accepted messages using SOH/STX/EOT framing
        for (i, prop) in proposals.enumerated() {
            switch prop.answer {
            case .accept:
                Log.d("B2F", "Sending message \(prop.messageId) (\(prop.compressedSize) bytes)")
                try await writeCompressed(proposal: prop)
                mailbox.markSent(messageId: batch[i].messageId)
                progress.messagesSent += 1
                progress.bytesTransferred += prop.compressedSize
                updateProgress(phase: "Sende", detail: "Nachricht \(progress.messagesSent)/\(proposals.count)")
            case .reject:
                Log.d("B2F", "Message \(prop.messageId) rejected (already received)")
                mailbox.markSent(messageId: batch[i].messageId)
            case .defer_, .hold:
                Log.d("B2F", "Message \(prop.messageId) deferred")
            }
        }

        return false
    }

    // MARK: - Inbound (Receiving)

    private func handleInbound() async throws -> Bool {
        var ourChecksum: Int64 = 0
        var proposals = [B2FProposal]()
        var quitReceived = false

        loop: while true {
            let line = try await transport.receiveLine()
            Log.d("B2F", "RX: \(line)")

            // Ignore comments
            if line.isEmpty || line.first == ";" { continue }

            guard line.count >= 2, line.first == "F" else {
                throw WinlinkError.protocolError("Unerwartete Zeile: \(line)")
            }

            let cmd = String(line.prefix(2))
            switch cmd {
            case "FA", "FB", "FC", "FD":
                // Proposal line — accumulate checksum
                for c in line.unicodeScalars {
                    ourChecksum += Int64(c.value)
                }
                ourChecksum += Int64(Character("\r").asciiValue ?? 13)

                let prop = try parseProposal(line)
                proposals.append(prop)
                Log.d("B2F", "Proposal: \(prop.messageId) (\(prop.compressedSize) bytes)")

            case "FF":
                Log.d("B2F", "Remote has no more messages")
                break loop

            case "FQ":
                Log.d("B2F", "Remote sends quit")
                quitReceived = true
                break loop

            case "F>":
                // Verify proposal block checksum
                ourChecksum = (-ourChecksum) & 0xFF
                let theirStr = line.count > 3 ? String(line.dropFirst(3)) : "0"
                let theirs = Int64(theirStr, radix: 16) ?? 0
                if theirs != ourChecksum {
                    throw WinlinkError.protocolError("Checksum-Fehler: erwartet \(ourChecksum), empfangen \(theirs)")
                }
                Log.d("B2F", "Proposal-Checksum OK (\(ourChecksum))")

                if proposals.isEmpty { break loop }

                // Send our answers
                try await writeProposalAnswers(proposals)
                break loop

            default:
                throw WinlinkError.protocolError("Unbekanntes Kommando: \(cmd)")
            }
        }

        // Receive accepted messages
        for i in 0..<proposals.count {
            guard proposals[i].answer == .accept else { continue }

            Log.d("B2F", "Empfange Nachricht \(proposals[i].messageId)...")
            try await readCompressed(proposal: &proposals[i])

            let decompressed = lzhuf.decompress(proposals[i].compressedData)
            if let message = parseReceivedMessage(data: decompressed, proposal: proposals[i]) {
                mailbox.storeInbox(message: message)
                progress.messagesReceived += 1
                progress.bytesTransferred += proposals[i].compressedSize
                updateProgress(phase: "Empfang", detail: "\(progress.messagesReceived) empfangen")
            }
        }

        return quitReceived
    }

    // MARK: - Proposal Answer

    private func writeProposalAnswers(_ proposals: [B2FProposal]) async throws {
        var answers = ""
        for prop in proposals {
            if mailbox.hasMessage(id: prop.messageId) {
                answers += "-"  // Already have it
                Log.d("B2F", "Proposal \(prop.messageId) reject (already exists)")
            } else {
                answers += "+"  // Accept it
                Log.d("B2F", "Proposal \(prop.messageId) accept")
            }
        }
        let line = "FS \(answers)"
        Log.d("B2F", "TX: \(line)")
        try await transport.sendLine(line)
    }

    // MARK: - SOH/STX/EOT Compressed Data Transfer (matches wl2k-go writeCompressed)

    /// Sends compressed data with SOH/STX/EOT framing.
    private func writeCompressed(proposal: B2FProposal) async throws {
        let data = proposal.compressedData
        guard data.count >= 6 else {
            throw WinlinkError.protocolError("Komprimierte Daten zu kurz")
        }

        // SOH header: SOH + headerLen + title + NUL + offset + NUL
        let title = proposal.title
        let offsetStr = "0"
        let headerLen = title.count + offsetStr.count + 2

        try await transport.sendByte(B2FProtocol.chrSOH)
        try await transport.sendByte(UInt8(headerLen & 0xFF))
        try await transport.sendData(Data(title.utf8))
        try await transport.sendByte(B2FProtocol.chrNUL)
        try await transport.sendData(Data(offsetStr.utf8))
        try await transport.sendByte(B2FProtocol.chrNUL)

        // Data blocks: STX + len + data (max 125 bytes per chunk)
        var offset = 0
        var checksum: Int = 0

        while offset < data.count {
            let remaining = data.count - offset
            let chunkLen = min(remaining, B2FProtocol.maxMsgLength)

            try await transport.sendByte(B2FProtocol.chrSTX)
            try await transport.sendByte(UInt8(chunkLen))

            let chunk = data[offset..<(offset + chunkLen)]
            try await transport.sendData(chunk)

            for byte in chunk {
                checksum = (checksum + Int(byte)) % 256
            }

            offset += chunkLen
            Log.d("B2F", "TX Block: \(chunkLen) bytes (offset \(offset)/\(data.count))")
        }

        // EOT + checksum
        checksum = (-checksum) & 0xFF
        try await transport.sendByte(B2FProtocol.chrEOT)
        try await transport.sendByte(UInt8(checksum))
        Log.d("B2F", "TX EOT, checksum=\(checksum)")
    }

    /// Receives compressed data with SOH/STX/EOT framing.
    private func readCompressed(proposal: inout B2FProposal) async throws {
        // Expect SOH
        let firstByte = try await transport.receiveByte()
        guard firstByte == B2FProtocol.chrSOH else {
            if firstByte == Character("*").asciiValue {
                let errLine = try await transport.receiveLine()
                throw WinlinkError.protocolError("CMS-Fehler: \(errLine)")
            }
            throw WinlinkError.protocolError("SOH erwartet, erhalten: \(firstByte)")
        }

        // Read header length
        let headerLen = Int(try await transport.receiveByte())

        // Read title (until NUL)
        var titleBytes = Data()
        while true {
            let b = try await transport.receiveByte()
            if b == B2FProtocol.chrNUL { break }
            titleBytes.append(b)
        }
        proposal.title = String(data: titleBytes, encoding: .utf8) ?? ""

        // Read offset (until NUL)
        var offsetBytes = Data()
        while true {
            let b = try await transport.receiveByte()
            if b == B2FProtocol.chrNUL { break }
            offsetBytes.append(b)
        }

        // Verify header length
        let actualHeaderLen = titleBytes.count + offsetBytes.count + 2
        if headerLen != actualHeaderLen {
            Log.d("B2F", "Header length mismatch: expected \(headerLen), actual \(actualHeaderLen)")
        }

        Log.d("B2F", "Receiving: '\(proposal.title)' offset=\(String(data: offsetBytes, encoding: .utf8) ?? "0")")

        // Read data blocks
        var buf = Data()
        var checksum: Int = 0

        while true {
            let c = try await transport.receiveByte()

            switch c {
            case B2FProtocol.chrSTX:
                let lenByte = try await transport.receiveByte()
                let blockLen = lenByte == 0 ? 256 : Int(lenByte)

                let blockData = try await transport.receiveData(count: blockLen)
                buf.append(blockData)
                for byte in blockData {
                    checksum = (checksum + Int(byte)) % 256
                }
                Log.d("B2F", "RX Block: \(blockLen) bytes (total: \(buf.count))")

            case B2FProtocol.chrEOT:
                let csumByte = try await transport.receiveByte()
                checksum = (checksum + Int(csumByte)) % 256
                guard checksum == 0 else {
                    throw WinlinkError.protocolError("Daten-Checksum falsch")
                }
                guard buf.count == proposal.compressedSize else {
                    throw WinlinkError.protocolError("Datenlänge: erwartet \(proposal.compressedSize), empfangen \(buf.count)")
                }
                proposal.compressedData = buf
                Log.d("B2F", "RX complete: \(buf.count) bytes, checksum OK")
                return

            default:
                throw WinlinkError.protocolError("Unerwartetes Byte im Datenstrom: \(c)")
            }
        }
    }

    // MARK: - Proposal Parsing

    private func parseProposal(_ line: String) throws -> B2FProposal {
        // Format: "FC EM MID SIZE CSIZE OFFSET" or "FC P FROM TO MID SIZE CSIZE OFFSET"
        let parts = line.split(separator: " ")
        guard parts.count >= 5 else {
            throw WinlinkError.protocolError("Ungültiger Proposal: \(line)")
        }

        let code = line.count > 1 ? line[line.index(line.startIndex, offsetBy: 1)] : "C"
        let msgType = String(parts[1])
        let messageId = String(parts[2])
        let size = Int(parts[3]) ?? 0
        let compressedSize = Int(parts[4]) ?? 0
        let offset = parts.count > 5 ? (Int(parts[5]) ?? 0) : 0

        guard size > 0, compressedSize > 0 else {
            throw WinlinkError.protocolError("Proposal mit ungültiger Größe: \(line)")
        }

        return B2FProposal(
            code: code,
            msgType: msgType,
            from: "",  // Filled from message content
            to: "",
            messageId: messageId,
            uncompressedSize: size,
            compressedSize: compressedSize,
            offset: offset
        )
    }

    // MARK: - Message Parsing

    private func parseReceivedMessage(data: Data, proposal: B2FProposal) -> WinlinkMessage? {
        guard let body = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) else {
            Log.d("B2F", "Message could not be decoded")
            return nil
        }

        // Parse MIME-style headers (case-insensitive)
        var headers: [String: String] = [:]
        var messageBody = ""
        let lines = body.components(separatedBy: "\r\n")
        var headerEndIdx = 0

        for (idx, line) in lines.enumerated() {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                headerEndIdx = idx
                break
            }
            if let colonIdx = line.firstIndex(of: ":") {
                let key = String(line[..<colonIdx]).trimmingCharacters(in: .whitespaces).lowercased()
                let value = String(line[line.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }

        if headerEndIdx + 1 < lines.count {
            messageBody = lines[(headerEndIdx + 1)...].joined(separator: "\n")
        }

        Log.d("B2F", "Message parsed: from=\(headers["from"] ?? "?") subject=\(headers["subject"] ?? "?")")

        return WinlinkMessage(
            messageId: proposal.messageId,
            from: headers["from"] ?? proposal.from,
            to: headers["to"] ?? account.callsign,
            subject: headers["subject"] ?? "(Kein Betreff)",
            body: messageBody.trimmingCharacters(in: .whitespacesAndNewlines),
            date: Date(),
            mimeType: headers["content-type"] ?? "text/plain",
            folder: .inbox,
            attachments: [],
            isRead: false,
            rawData: data
        )
    }

    // MARK: - Helpers

    private func updateProgress(phase: String, detail: String) {
        progress.phase = phase
        progress.detail = detail
        onProgress?(progress)
    }
}
