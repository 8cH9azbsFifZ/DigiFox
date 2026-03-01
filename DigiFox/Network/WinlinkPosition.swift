/// Winlink Position Reports — GPS-Positionsberichte.
///
/// Sendet GPS-basierte Positionsberichte über Winlink.
/// Nutzt den bereits vorhandenen LocationManager der App.
///
/// Positionsberichte werden im Winlink-Standardformat gesendet:
/// ;PRIOR:ROUTINE;LAT:48.1234N;LON:011.5678E;ALT:520;COMMENT:DigiFox
///
/// Referenz: https://github.com/la5nta/pat (position reporting)

import Foundation
import CoreLocation

// MARK: - Position Report Model

/// Winlink-Positionsbericht
struct WinlinkPositionReport: Codable, Sendable {
    /// Breitengrad
    let latitude: Double
    /// Längengrad
    let longitude: Double
    /// Höhe über Meeresspiegel in Metern
    let altitude: Double?
    /// Geschwindigkeit in km/h
    let speed: Double?
    /// Kurs in Grad
    let course: Double?
    /// Zeitstempel
    let timestamp: Date
    /// Kommentar (max 80 Zeichen)
    let comment: String
    /// Priorität
    let priority: PositionPriority

    /// Formatiert als Winlink-Position-Report
    var formattedReport: String {
        let latDir = latitude >= 0 ? "N" : "S"
        let lonDir = longitude >= 0 ? "E" : "W"
        let absLat = abs(latitude)
        let absLon = abs(longitude)

        var report = ";PRIOR:\(priority.rawValue)"
        report += String(format: ";LAT:%07.4f%@", absLat, latDir)
        report += String(format: ";LON:%08.4f%@", absLon, lonDir)

        if let alt = altitude {
            report += String(format: ";ALT:%.0f", alt)
        }
        if let speed = speed, speed > 0 {
            report += String(format: ";SPD:%.0f", speed)
        }
        if let course = course, course >= 0 {
            report += String(format: ";CRS:%.0f", course)
        }

        let safeComment = String(comment.prefix(80)).replacingOccurrences(of: ";", with: ",")
        report += ";COMMENT:\(safeComment)"

        return report
    }

    /// Grid-Locator aus den Koordinaten berechnen (Maidenhead)
    var gridLocator: String {
        let lon = longitude + 180.0
        let lat = latitude + 90.0

        let a = Int(lon / 20.0)
        let b = Int(lat / 10.0)
        let c = Int((lon - Double(a * 20)) / 2.0)
        let d = Int(lat - Double(b * 10))
        let e = Int((lon - Double(a * 20) - Double(c * 2)) * 12.0)
        let f = Int((lat - Double(b * 10) - Double(d)) * 24.0)

        return String(format: "%c%c%d%d%c%c",
                       Character(UnicodeScalar(65 + a)!).asciiValue!,
                       Character(UnicodeScalar(65 + b)!).asciiValue!,
                       c, d,
                       Character(UnicodeScalar(97 + e)!).asciiValue!,
                       Character(UnicodeScalar(97 + f)!).asciiValue!)
    }
}

/// Priorität des Positionsberichts
enum PositionPriority: String, Codable, CaseIterable, Sendable {
    case routine = "ROUTINE"
    case welfare = "WELFARE"
    case priority = "PRIORITY"
    case emergency = "EMERGENCY"

    var label: String {
        switch self {
        case .routine: return "Routine"
        case .welfare: return "Wohlbefinden"
        case .priority: return "Priorität"
        case .emergency: return "Notfall"
        }
    }

    var systemImage: String {
        switch self {
        case .routine: return "location"
        case .welfare: return "heart"
        case .priority: return "exclamationmark.triangle"
        case .emergency: return "sos"
        }
    }
}

// MARK: - Position Report Manager

/// Verwaltet das Senden von Positionsberichten über Winlink.
final class WinlinkPositionManager {

    static let shared = WinlinkPositionManager()

    private let mailbox = WinlinkMailbox.shared

    /// Winlink Position Report Empfänger
    private let positionReportTo = "QTH"

    private init() {}

    /// Erstellt einen Positionsbericht aus CLLocation.
    func createReport(
        from location: CLLocation,
        comment: String = "DigiFox Position Report",
        priority: PositionPriority = .routine
    ) -> WinlinkPositionReport {
        WinlinkPositionReport(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            altitude: location.altitude > 0 ? location.altitude : nil,
            speed: location.speed > 0 ? location.speed * 3.6 : nil, // m/s → km/h
            course: location.course >= 0 ? location.course : nil,
            timestamp: location.timestamp,
            comment: comment,
            priority: priority
        )
    }

    /// Sendet einen Positionsbericht als Winlink-Nachricht.
    /// Die Nachricht wird in den Postausgang gelegt und beim nächsten
    /// Gateway-Connect automatisch gesendet.
    func sendPositionReport(
        report: WinlinkPositionReport,
        callsign: String
    ) {
        let subject = "POSITION REPORT"
        let body = report.formattedReport

        let message = WinlinkMessage(
            messageId: WinlinkMessage.generateId(callsign: callsign),
            from: "\(callsign.uppercased())@winlink.org",
            to: positionReportTo,
            subject: subject,
            body: body,
            date: report.timestamp,
            mimeType: "text/plain",
            folder: .outbox,
            attachments: [],
            isRead: true,
            rawData: Data(body.utf8)
        )

        mailbox.storeOutbox(message: message)
    }

    /// Letzter gesendeter Positionsbericht (aus Sent-Ordner).
    func lastSentPosition() -> WinlinkMessage? {
        return mailbox.messages(in: .sent)
            .filter { $0.subject == "POSITION REPORT" }
            .first
    }
}
