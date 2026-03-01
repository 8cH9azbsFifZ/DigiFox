import Foundation

/// PSK Reporter — Submit spots to pskreporter.info via IPFIX/UDP.
///
/// Ported from wave-owl/src/psk_reporter.py (Python).
/// Uses the IPFIX binary protocol (RFC 5101) with enterprise number 30351.
/// Spots are buffered and flushed every 5 minutes as a single UDP datagram.
///
/// Reference: IPFIX (RFC 5101) — https://tools.ietf.org/html/rfc5101
/// Reference: PSK Reporter protocol — https://pskreporter.info/pskdev.html
/// Origin: wave-owl/src/psk_reporter.py — class PSKReporter(SpotReporter)
final class PSKReporter: SpotReporting {

    // MARK: - IPFIX Constants

    private static let ipfixVersion: UInt16 = 0x000A
    private static let enterpriseNr: UInt32 = 30351           // 0x768F — Philip Gladstone
    private static let maxDatagramSize = 1200
    private static let templateRetransmitInterval: TimeInterval = 3600.0  // 1 hour

    // IPFIX set IDs
    private static let templateSetID: UInt16 = 2
    private static let optionsTemplateSetID: UInt16 = 3

    // Template IDs
    private static let receiverTemplateID: UInt16 = 0x9992
    private static let senderTemplateID: UInt16 = 0x9993

    // Enterprise-specific IE IDs (enterprise number 30351)
    private static let ieSenderCallsign: UInt16 = 1
    private static let ieReceiverCallsign: UInt16 = 2
    private static let ieSenderLocator: UInt16 = 3
    private static let ieReceiverLocator: UInt16 = 4
    private static let ieFrequency: UInt16 = 5
    private static let ieSNR: UInt16 = 6
    private static let ieDecoderSoftware: UInt16 = 8
    private static let ieAntennaInfo: UInt16 = 9
    private static let ieMode: UInt16 = 10
    private static let ieInfoSource: UInt16 = 11
    // flowStartSeconds uses IANA-standard IE 150 (NOT enterprise-specific)
    private static let ieFlowStartSeconds: UInt16 = 150

    // MARK: - Properties

    private let callsign: String
    private let grid: String
    private let software: String
    private let antennaInfo: String
    private let host: String
    private let port: UInt16
    private let flushInterval: TimeInterval

    private var spotBuffer: [Spot] = []
    private let bufferLock = NSLock()
    private var flushTimer: Timer?
    private var isRunning = false

    private var sequenceNr: UInt32 = 0
    private let observationDomainID: UInt32 = UInt32.random(in: 1...UInt32.max)
    private var packetsSent: Int = 0
    private var lastTemplateTime: Date = .distantPast

    // MARK: - Init

    /// - Parameters:
    ///   - callsign: Station callsign.
    ///   - grid: Maidenhead grid locator.
    ///   - software: Software name reported to PSK Reporter.
    ///   - antenna: Antenna description (e.g. "Random Wire", "3-el Yagi").
    ///   - host: PSK Reporter server hostname.
    ///   - port: PSK Reporter server port.
    ///   - flushInterval: Seconds between automatic flushes (default 300).
    init(callsign: String, grid: String, software: String = "DigiFox",
         antenna: String = "", host: String = "report.pskreporter.info",
         port: UInt16 = 4739, flushInterval: TimeInterval = 300.0) {
        self.callsign = callsign
        self.grid = grid
        self.software = software
        self.antennaInfo = antenna
        self.host = host
        self.port = port
        self.flushInterval = flushInterval
    }

    // MARK: - SpotReporting

    func start() {
        isRunning = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.flushTimer = Timer.scheduledTimer(withTimeInterval: self.flushInterval, repeats: true) { [weak self] _ in
                self?.flush()
            }
        }
        Log.d("PSKReporter", "Started (host=\(host):\(port), call=\(callsign), grid=\(grid), interval=\(flushInterval)s)")
    }

    func stop() {
        isRunning = false
        flushTimer?.invalidate()
        flushTimer = nil
        flush()
        Log.d("PSKReporter", "Stopped")
    }

    func report(_ spot: Spot) {
        bufferLock.lock()
        spotBuffer.append(spot)
        bufferLock.unlock()
    }

    // MARK: - Flush

    private func flush() {
        bufferLock.lock()
        guard !spotBuffer.isEmpty else { bufferLock.unlock(); return }
        let spots = spotBuffer
        spotBuffer.removeAll()
        bufferLock.unlock()

        let includeTemplates = needsTemplates()

        var payload = Data()
        if includeTemplates {
            payload.append(Self.buildReceiverDescriptor())
            payload.append(Self.buildSenderDescriptor())
            lastTemplateTime = Date()
        }

        payload.append(buildReceiverRecord())
        payload.append(Self.buildSenderRecords(spots))

        let totalLength = 16 + payload.count
        var datagram = Self.buildIPFIXHeader(length: UInt16(totalLength), seqNr: sequenceNr, domainID: observationDomainID)
        datagram.append(payload)
        sequenceNr += 1

        sendDatagram(datagram)
        Log.d("PSKReporter", "Flushed \(spots.count) spots (\(datagram.count) bytes)")
    }

    private func needsTemplates() -> Bool {
        if packetsSent < 3 { return true }
        return Date().timeIntervalSince(lastTemplateTime) >= Self.templateRetransmitInterval
    }

    // MARK: - UDP Send

    private func sendDatagram(_ data: Data) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let fd = socket(AF_INET, SOCK_DGRAM, 0)
            guard fd >= 0 else {
                Log.d("PSKReporter", "Failed to create UDP socket")
                return
            }
            defer { close(fd) }

            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = self.port.bigEndian

            // Resolve hostname
            guard let host = self.host.cString(using: .ascii),
                  let hostent = gethostbyname(host) else {
                Log.d("PSKReporter", "Failed to resolve \(self.host)")
                return
            }
            memcpy(&addr.sin_addr, hostent.pointee.h_addr_list[0]!, Int(hostent.pointee.h_length))

            data.withUnsafeBytes { buf in
                withUnsafePointer(to: &addr) { addrPtr in
                    addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        sendto(fd, buf.baseAddress!, buf.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            self.packetsSent += 1
        }
    }

    // MARK: - IPFIX Binary Encoding

    private static func buildIPFIXHeader(length: UInt16, seqNr: UInt32, domainID: UInt32) -> Data {
        var data = Data(capacity: 16)
        data.appendBigEndian(ipfixVersion)
        data.appendBigEndian(length)
        data.appendBigEndian(UInt32(Date().timeIntervalSince1970))
        data.appendBigEndian(seqNr)
        data.appendBigEndian(domainID)
        return data
    }

    private static func buildReceiverDescriptor() -> Data {
        // Options Template Set for receiver (template ID 0x9992, 4 fields, 1 scope)
        let ieIDs: [UInt16] = [ieReceiverCallsign, ieReceiverLocator, ieDecoderSoftware, ieAntennaInfo]
        var fields = Data()
        for ie in ieIDs {
            fields.appendBigEndian(0x8000 | ie)  // enterprise bit set
            fields.appendBigEndian(UInt16(0xFFFF))  // variable length
            fields.appendBigEndian(enterpriseNr)
        }

        var templateRecord = Data()
        templateRecord.appendBigEndian(receiverTemplateID)
        templateRecord.appendBigEndian(UInt16(4))  // field count
        templateRecord.appendBigEndian(UInt16(1))  // scope field count
        templateRecord.append(fields)

        // Pad to 4-byte boundary
        let padLen = (4 - templateRecord.count % 4) % 4
        templateRecord.append(Data(repeating: 0, count: padLen))

        var set = Data()
        let setLength = UInt16(4 + templateRecord.count)
        set.appendBigEndian(optionsTemplateSetID)
        set.appendBigEndian(setLength)
        set.append(templateRecord)
        return set
    }

    private static func buildSenderDescriptor() -> Data {
        // Template Set for sender (template ID 0x9993, 6 fields)
        let enterpriseFields: [(UInt16, UInt16)] = [
            (ieSenderCallsign, 0xFFFF),  // variable length
            (ieFrequency, 4),
            (ieSNR, 1),
            (ieMode, 0xFFFF),            // variable length
            (ieInfoSource, 1),
        ]
        var fields = Data()
        for (ie, len) in enterpriseFields {
            fields.appendBigEndian(0x8000 | ie)
            fields.appendBigEndian(len)
            fields.appendBigEndian(enterpriseNr)
        }
        // IANA-standard flowStartSeconds (IE 150, 4 bytes — no enterprise bit)
        fields.appendBigEndian(ieFlowStartSeconds)
        fields.appendBigEndian(UInt16(4))

        var templateRecord = Data()
        templateRecord.appendBigEndian(senderTemplateID)
        templateRecord.appendBigEndian(UInt16(6))  // field count
        templateRecord.append(fields)

        var set = Data()
        let setLength = UInt16(4 + templateRecord.count)
        set.appendBigEndian(templateSetID)
        set.appendBigEndian(setLength)
        set.append(templateRecord)
        return set
    }

    private func buildReceiverRecord() -> Data {
        var record = Data()
        record.append(Self.encodeVarlenString(callsign))
        record.append(Self.encodeVarlenString(grid))
        record.append(Self.encodeVarlenString(software))
        record.append(Self.encodeVarlenString(antennaInfo))

        let padLen = (4 - record.count % 4) % 4
        record.append(Data(repeating: 0, count: padLen))

        var set = Data()
        let setLength = UInt16(4 + record.count)
        set.appendBigEndian(Self.receiverTemplateID)
        set.appendBigEndian(setLength)
        set.append(record)
        return set
    }

    private static func buildSenderRecords(_ spots: [Spot]) -> Data {
        var records = Data()
        let now = UInt32(Date().timeIntervalSince1970)
        for spot in spots {
            let snrClamped = Int8(clamping: spot.snr)
            records.append(encodeVarlenString(spot.callsign))
            records.appendBigEndian(UInt32(spot.frequency))
            records.append(Data([UInt8(bitPattern: snrClamped)]))
            records.append(encodeVarlenString(spot.mode))
            records.append(Data([0x01]))  // informationSource: auto-decoded
            records.appendBigEndian(now)
        }
        var set = Data()
        let setLength = UInt16(4 + records.count)
        set.appendBigEndian(senderTemplateID)
        set.appendBigEndian(setLength)
        set.append(records)
        return set
    }

    /// Encode a string with 1-byte length prefix + ASCII content.
    private static func encodeVarlenString(_ s: String) -> Data {
        let ascii = Array(s.utf8.prefix(254))
        var data = Data(capacity: 1 + ascii.count)
        data.append(UInt8(ascii.count))
        data.append(contentsOf: ascii)
        return data
    }
}

// MARK: - Data Big-Endian Helpers

private extension Data {
    mutating func appendBigEndian(_ value: UInt16) {
        var big = value.bigEndian
        append(Data(bytes: &big, count: 2))
    }
    mutating func appendBigEndian(_ value: UInt32) {
        var big = value.bigEndian
        append(Data(bytes: &big, count: 4))
    }
}
