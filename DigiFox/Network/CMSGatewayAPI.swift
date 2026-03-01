/// CMS Gateway API — Abfrage verfügbarer Winlink RMS-Gateways.
///
/// Verwendet die offizielle Winlink CMS API um aktive RMS-Gateways
/// in der Nähe zu finden, inklusive Frequenzen und Betriebsmodi.
///
/// API-Endpunkt: https://api.winlink.org/gateway/listing
///
/// Referenz: https://github.com/la5nta/pat (gateway directory)
/// Referenz: https://api.winlink.org (CMS API Dokumentation)

import Foundation
import CoreLocation

// MARK: - Gateway Model

/// Ein Winlink RMS-Gateway (Radio Message Server)
struct RMSGateway: Identifiable, Codable, Sendable {
    /// Gateway-Rufzeichen
    let callsign: String
    /// Frequenz in Hz
    let frequency: Double
    /// Betriebsmodus (ARDOP, VARA, Pactor, etc.)
    let mode: String
    /// Gateway-Standort
    let latitude: Double
    let longitude: Double
    /// Grid-Locator
    let gridSquare: String
    /// Letzte Aktualisierung
    let lastUpdate: Date?
    /// Service-Code (PUBLIC, EMCOM, etc.)
    let serviceCode: String?
    /// Entfernung zum eigenen Standort in km (wird berechnet)
    var distanceKm: Double?

    var id: String { "\(callsign)-\(Int(frequency))" }

    /// Frequenz formatiert als MHz
    var frequencyMHz: String {
        String(format: "%.4f MHz", frequency / 1_000_000)
    }

    /// Band-Bezeichnung basierend auf Frequenz
    var band: String {
        switch frequency {
        case 1_800_000..<2_000_000: return "160m"
        case 3_500_000..<4_000_000: return "80m"
        case 7_000_000..<7_300_000: return "40m"
        case 10_100_000..<10_150_000: return "30m"
        case 14_000_000..<14_350_000: return "20m"
        case 18_068_000..<18_168_000: return "17m"
        case 21_000_000..<21_450_000: return "15m"
        case 24_890_000..<24_990_000: return "12m"
        case 28_000_000..<29_700_000: return "10m"
        default: return "?"
        }
    }
}

// MARK: - CMS API Response

/// API-Antwort des CMS Gateway Listing
private struct CMSGatewayResponse: Codable {
    let GatewayList: [CMSGatewayEntry]?

    struct CMSGatewayEntry: Codable {
        let Callsign: String?
        let Frequency: Double?
        let Mode: String?
        let Gridsquare: String?
        let Latitude: Double?
        let Longitude: Double?
        let LastUpdate: String?
        let ServiceCode: String?
    }
}

// MARK: - CMS Gateway API

/// API-Client für die Winlink CMS Gateway-Datenbank.
///
/// Ermöglicht die Suche nach verfügbaren RMS-Gateways nach:
/// - Entfernung zum eigenen Standort
/// - Band / Frequenzbereich
/// - Betriebsmodus (ARDOP, VARA, etc.)
final class CMSGatewayAPI {

    /// CMS API Basis-URL
    static let baseURL = "https://api.winlink.org"

    /// API-Key (öffentlich für Gateway-Listing)
    private let apiKey = "EMCOMM"

    /// Cache für Gateway-Liste
    private var cachedGateways: [RMSGateway] = []
    private var cacheDate: Date?
    private let cacheTimeout: TimeInterval = 3600 // 1 Stunde

    static let shared = CMSGatewayAPI()
    private init() {}

    // MARK: - Public API

    /// Alle ARDOP-fähigen Gateways abrufen.
    func fetchARDOPGateways() async throws -> [RMSGateway] {
        return try await fetchGateways(mode: "ARDOP")
    }

    /// Gateways nach Modus filtern.
    func fetchGateways(mode: String? = nil) async throws -> [RMSGateway] {
        // Check cache
        if let cacheDate = cacheDate,
           Date().timeIntervalSince(cacheDate) < cacheTimeout,
           !cachedGateways.isEmpty {
            let filtered = mode == nil ? cachedGateways : cachedGateways.filter { $0.mode == mode }
            return filtered
        }

        let gateways = try await fetchFromAPI(mode: mode)
        cachedGateways = gateways
        cacheDate = Date()
        return gateways
    }

    /// Nächste Gateways zum angegebenen Standort.
    func nearestGateways(
        latitude: Double,
        longitude: Double,
        mode: String = "ARDOP",
        maxCount: Int = 20,
        maxDistanceKm: Double = 5000
    ) async throws -> [RMSGateway] {
        var gateways = try await fetchGateways(mode: mode)

        let myLocation = CLLocation(latitude: latitude, longitude: longitude)

        // Berechne Entfernungen
        gateways = gateways.map { gw in
            var gateway = gw
            let gwLocation = CLLocation(latitude: gw.latitude, longitude: gw.longitude)
            gateway.distanceKm = myLocation.distance(from: gwLocation) / 1000.0
            return gateway
        }

        // Filtere und sortiere nach Entfernung
        return gateways
            .filter { ($0.distanceKm ?? Double.infinity) <= maxDistanceKm }
            .sorted { ($0.distanceKm ?? Double.infinity) < ($1.distanceKm ?? Double.infinity) }
            .prefix(maxCount)
            .map { $0 }
    }

    /// Gateways für ein bestimmtes Band.
    func gatewaysForBand(_ bandId: String, mode: String = "ARDOP") async throws -> [RMSGateway] {
        let gateways = try await fetchGateways(mode: mode)
        return gateways.filter { $0.band == bandId }
    }

    /// Cache leeren.
    func clearCache() {
        cachedGateways.removeAll()
        cacheDate = nil
    }

    // MARK: - API Request

    private func fetchFromAPI(mode: String?) async throws -> [RMSGateway] {
        var urlString = "\(CMSGatewayAPI.baseURL)/channel/list?key=\(apiKey)&format=json"
        if let mode = mode {
            urlString += "&mode=\(mode)"
        }

        guard let url = URL(string: urlString) else {
            throw WinlinkError.connectionFailed("Ungültige API-URL")
        }

        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw WinlinkError.connectionFailed("CMS API Fehler")
        }

        let decoder = JSONDecoder()
        let apiResponse = try decoder.decode(CMSGatewayResponse.self, from: data)

        guard let entries = apiResponse.GatewayList else {
            return []
        }

        let dateFormatter = ISO8601DateFormatter()

        return entries.compactMap { entry -> RMSGateway? in
            guard let callsign = entry.Callsign,
                  let frequency = entry.Frequency,
                  let mode = entry.Mode else {
                return nil
            }

            return RMSGateway(
                callsign: callsign,
                frequency: frequency * 1000, // API returns kHz, we use Hz
                mode: mode,
                latitude: entry.Latitude ?? 0,
                longitude: entry.Longitude ?? 0,
                gridSquare: entry.Gridsquare ?? "",
                lastUpdate: entry.LastUpdate != nil ? dateFormatter.date(from: entry.LastUpdate!) : nil,
                serviceCode: entry.ServiceCode,
                distanceKm: nil
            )
        }
    }
}
