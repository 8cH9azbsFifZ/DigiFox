/// Tests für die Winlink-Implementierung: LZHUF, Account, Mailbox, B2F, Position.
///
/// Testet die Kernkomponenten der Winlink-Funktionalität.

import XCTest
@testable import DigiFox

final class WinlinkTests: XCTestCase {

    // MARK: - LZHUF Compression Tests

    func testLZHUFRoundtrip() {
        let codec = LZHUFCodec()
        let original = "Dies ist ein Test der LZHUF-Kompression für Winlink. 73 de DL1ABC"
        let data = Data(original.utf8)

        let compressed = codec.compress(data)
        XCTAssertFalse(compressed.isEmpty, "Komprimierte Daten sollten nicht leer sein")

        let decompressed = LZHUFCodec().decompress(compressed)
        XCTAssertEqual(decompressed, data, "Dekomprimierte Daten sollten dem Original entsprechen")
    }

    func testLZHUFEmptyData() {
        let codec = LZHUFCodec()
        let compressed = codec.compress(Data())
        XCTAssertEqual(compressed.count, 4, "Leere Daten ergeben nur den 4-Byte Header")

        let decompressed = LZHUFCodec().decompress(compressed)
        XCTAssertTrue(decompressed.isEmpty, "Leere Daten bleiben leer")
    }

    func testLZHUFRepetitiveData() {
        let codec = LZHUFCodec()
        let original = String(repeating: "ABCABC", count: 100)
        let data = Data(original.utf8)

        let compressed = codec.compress(data)
        // Repetitive data should compress well
        XCTAssertLessThan(compressed.count, data.count, "Repetitive Daten sollten komprimierbar sein")

        let decompressed = LZHUFCodec().decompress(compressed)
        XCTAssertEqual(decompressed, data, "Roundtrip muss exakt sein")
    }

    func testLZHUFBinaryData() {
        let codec = LZHUFCodec()
        var data = Data(count: 256)
        for i in 0..<256 {
            data[i] = UInt8(i)
        }

        let compressed = codec.compress(data)
        let decompressed = LZHUFCodec().decompress(compressed)
        XCTAssertEqual(decompressed, data, "Binärdaten-Roundtrip muss exakt sein")
    }

    // MARK: - Winlink Account Tests

    func testWinlinkAccountEmail() {
        let account = WinlinkAccount(
            callsign: "dl1abc",
            password: "secret"
        )
        XCTAssertEqual(account.winlinkEmail, "DL1ABC@winlink.org")
    }

    func testWinlinkAccountConfigured() {
        let configured = WinlinkAccount(callsign: "DL1ABC", password: "pass")
        XCTAssertTrue(configured.isConfigured)

        let notConfigured = WinlinkAccount(callsign: "", password: "")
        XCTAssertFalse(notConfigured.isConfigured)
    }

    func testChallengeResponse() {
        let manager = WinlinkAccountManager.shared
        let response = manager.challengeResponse(challenge: "test123", password: "mypassword")
        XCTAssertFalse(response.isEmpty, "Challenge-Response sollte nicht leer sein")
        XCTAssertEqual(response.count, 32, "MD5-ähnlicher Hash sollte 32 Hex-Zeichen lang sein")

        // Same input → same output
        let response2 = manager.challengeResponse(challenge: "test123", password: "mypassword")
        XCTAssertEqual(response, response2, "Gleiche Eingabe → gleiche Ausgabe")

        // Different input → different output
        let response3 = manager.challengeResponse(challenge: "test456", password: "mypassword")
        XCTAssertNotEqual(response, response3, "Verschiedene Eingabe → verschiedene Ausgabe")
    }

    // MARK: - Winlink Message Tests

    func testMessageIdGeneration() {
        let id1 = WinlinkMessage.generateId(callsign: "DL1ABC")
        let id2 = WinlinkMessage.generateId(callsign: "DL1ABC")
        XCTAssertTrue(id1.hasPrefix("DL1A"), "ID sollte mit Callsign-Prefix beginnen")
        XCTAssertEqual(id1.count, 10, "ID sollte 10 Zeichen lang sein")
        XCTAssertNotEqual(id1, id2, "IDs sollten eindeutig sein")
    }

    func testMessageMimeData() {
        let message = WinlinkMessage(
            messageId: "DL1ATEST01",
            from: "DL1ABC@winlink.org",
            to: "DL2XYZ@winlink.org",
            subject: "Test",
            body: "Hallo Welt",
            date: Date(),
            folder: .outbox,
            attachments: [],
            isRead: true,
            rawData: Data()
        )

        let mime = message.mimeData
        let mimeString = String(data: mime, encoding: .utf8)!
        XCTAssertTrue(mimeString.contains("Mid: DL1ATEST01"))
        XCTAssertTrue(mimeString.contains("From: DL1ABC@winlink.org"))
        XCTAssertTrue(mimeString.contains("To: DL2XYZ@winlink.org"))
        XCTAssertTrue(mimeString.contains("Subject: Test"))
        XCTAssertTrue(mimeString.contains("Hallo Welt"))
    }

    // MARK: - B2F Protocol Tests

    func testB2FProposalLine() {
        let proposal = B2FProposal(
            messageType: "P",
            from: "DL1ABC",
            to: "DL2XYZ@winlink.org",
            messageId: "DL1ATEST01",
            uncompressedSize: 1024,
            compressedSize: 512,
            offset: 0
        )

        let line = proposal.proposalLine
        XCTAssertTrue(line.hasPrefix("FC "), "Proposal beginnt mit FC")
        XCTAssertTrue(line.contains("DL1ABC"), "Proposal enthält Absender")
        XCTAssertTrue(line.contains("DL1ATEST01"), "Proposal enthält Message-ID")
    }

    func testB2FSIDFormat() {
        let sid = B2FProtocol.sid
        XCTAssertTrue(sid.hasPrefix("["), "SID beginnt mit [")
        XCTAssertTrue(sid.hasSuffix("]"), "SID endet mit ]")
        XCTAssertTrue(sid.contains("DigiFox"), "SID enthält App-Name")
        XCTAssertTrue(sid.contains("B2F"), "SID enthält Protokoll-Flag")
    }

    // MARK: - Position Report Tests

    func testPositionReportFormat() {
        let report = WinlinkPositionReport(
            latitude: 48.1234,
            longitude: 11.5678,
            altitude: 520,
            speed: 5.0,
            course: 180,
            timestamp: Date(),
            comment: "DigiFox Test",
            priority: .routine
        )

        let formatted = report.formattedReport
        XCTAssertTrue(formatted.contains(";PRIOR:ROUTINE"), "Enthält Priorität")
        XCTAssertTrue(formatted.contains("N"), "Enthält Nordrichtung")
        XCTAssertTrue(formatted.contains("E"), "Enthält Ostrichtung")
        XCTAssertTrue(formatted.contains(";ALT:520"), "Enthält Höhe")
        XCTAssertTrue(formatted.contains(";COMMENT:DigiFox Test"), "Enthält Kommentar")
    }

    func testGridLocator() {
        let report = WinlinkPositionReport(
            latitude: 48.1466,
            longitude: 11.7761,
            altitude: nil, speed: nil, course: nil,
            timestamp: Date(),
            comment: "Test",
            priority: .routine
        )

        let grid = report.gridLocator
        XCTAssertEqual(grid.count, 6, "Grid-Locator hat 6 Zeichen")
        XCTAssertTrue(grid.hasPrefix("JN"), "München ist in JN")
    }

    // MARK: - ARDOP Session Tests

    func testARDOPSessionInitialState() async {
        let session = ARDOPSession(callsign: "DL1ABC", bandwidth: .bw500)
        let state = await session.state
        XCTAssertEqual(state, .disconnected, "Initialer Zustand ist disconnected")
    }

    func testARDOPSessionListen() async {
        let session = ARDOPSession(callsign: "DL1ABC", bandwidth: .bw500)
        await session.listen()
        let state = await session.state
        XCTAssertEqual(state, .listening, "Nach listen() ist der Zustand listening")
    }

    func testARDOPSessionDisconnect() async {
        let session = ARDOPSession(callsign: "DL1ABC", bandwidth: .bw500)
        await session.listen()
        await session.disconnect()
        let state = await session.state
        XCTAssertEqual(state, .disconnected, "Nach disconnect() ist der Zustand disconnected")
    }

    func testARDOPSessionStats() async {
        let session = ARDOPSession(callsign: "DL1ABC")
        let stats = await session.getStats()
        XCTAssertEqual(stats.state, .disconnected)
        XCTAssertNil(stats.remoteCallsign)
        XCTAssertEqual(stats.txQueueBytes, 0)
        XCTAssertEqual(stats.rxBufferBytes, 0)
    }

    // MARK: - Attachment Tests

    func testMIMEEncoding() {
        let attachment = WinlinkAttachment(
            filename: "test.txt",
            mimeType: "text/plain",
            data: Data("Hallo Welt".utf8)
        )

        let (mimeType, data) = WinlinkAttachmentBuilder.encodeMIME(
            body: "Nachrichtentext",
            attachments: [attachment]
        )

        XCTAssertTrue(mimeType.contains("multipart/mixed"), "MIME-Type ist multipart")
        let content = String(data: data, encoding: .utf8)!
        XCTAssertTrue(content.contains("Nachrichtentext"), "Enthält Body")
        XCTAssertTrue(content.contains("test.txt"), "Enthält Dateiname")
    }

    func testAttachmentValidation() {
        let builder = WinlinkAttachmentBuilder(mode: .hf)
        let small = WinlinkAttachment(filename: "a.txt", mimeType: "text/plain", data: Data(count: 100))
        let validation = builder.validateTotalSize([small])
        XCTAssertTrue(validation.isValid, "Kleiner Anhang sollte gültig sein")

        let large = WinlinkAttachment(filename: "b.bin", mimeType: "application/octet-stream", data: Data(count: 200_000))
        let validation2 = builder.validateTotalSize([large])
        XCTAssertFalse(validation2.isValid, "Zu großer Anhang sollte ungültig sein")
    }

    // MARK: - WinlinkError Tests

    func testWinlinkErrorDescriptions() {
        let errors: [WinlinkError] = [
            .notConfigured,
            .authenticationFailed,
            .connectionFailed("Test"),
            .protocolError("Test"),
            .compressionError,
            .timeout
        ]

        for error in errors {
            XCTAssertNotNil(error.errorDescription, "\(error) sollte eine Beschreibung haben")
        }
    }
}
