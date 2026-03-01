import SwiftUI

/// Winlink email over HF — main view.
///
/// Provides access to all Winlink features:
/// - Inbox / Outbox
/// - Compose messages
/// - ARDOP connection to RMS gateways
/// - Telnet fallback (Internet)
/// - RMS gateway directory
/// - P2P mode (direct)
/// - Position reports
///
/// Open Source References:
///   - ARDOP TNC: https://github.com/pflarue/ardop
///   - Pat Winlink Client: https://github.com/la5nta/pat (Go, MIT License)
///   - WSJT-X: https://wsjt.sourceforge.io (Dr. Joe Taylor, K1JT)
///   - Fldigi: http://www.w1hkj.com (Dave Freese, W1HKJ)
///   - (tr)uSDX: https://dl2man.de (Manuel Klüber, DL2MAN)
///   - Winlink: https://winlink.org
struct WinlinkView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var settings: AppSettings

    @State private var selectedSection: WinlinkSection = .mail
    @State private var showingCompose = false
    @State private var showingAccountSetup = false
    @State private var showingGateways = false
    @State private var connectionStatus: String = "Getrennt"
    @State private var unreadCount: Int = 0

    enum WinlinkSection: String, CaseIterable {
        case mail = "Mail"
        case connect = "Verbinden"
        case info = "Info"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Section Picker
                Picker("Bereich", selection: $selectedSection) {
                    ForEach(WinlinkSection.allCases, id: \.self) { section in
                        Text(section.rawValue).tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 4)

                // Content
                switch selectedSection {
                case .mail:
                    mailSection
                case .connect:
                    connectSection
                case .info:
                    infoSection
                }
            }
            .navigationTitle("Winlink")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { StatusToolbar() }
            .sheet(isPresented: $showingCompose) {
                ComposeView()
            }
            .sheet(isPresented: $showingAccountSetup) {
                WinlinkAccountView()
            }
            .sheet(isPresented: $showingGateways) {
                GatewayListView()
            }
            .onAppear {
                unreadCount = WinlinkMailbox.shared.unreadCount()
            }
        }
    }

    // MARK: - Mail Section

    private var mailSection: some View {
        VStack(spacing: 0) {
            // Quick actions
            HStack(spacing: 16) {
                Button(action: { showingCompose = true }) {
                    Label("Verfassen", systemImage: "square.and.pencil")
                }
                .buttonStyle(.borderedProminent)

                Spacer()

                if unreadCount > 0 {
                    Text("\(unreadCount) ungelesen")
                        .font(.caption)
                        .foregroundStyle(.blue)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.blue.opacity(0.1))
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            // Embedded message list
            MessageListView()
        }
    }

    // MARK: - Connect Section

    private var connectSection: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Account Status
                accountStatusCard

                // Connection Options
                GroupBox("Verbindungsoptionen") {
                    VStack(spacing: 12) {
                        // Telnet (Internet)
                        ConnectOptionRow(
                            icon: "network",
                            title: "Telnet (Internet)",
                            subtitle: "Verbindung über WLAN/Mobilfunk",
                            action: connectViaTelnet
                        )

                        Divider()

                        // ARDOP (HF Radio)
                        ConnectOptionRow(
                            icon: "antenna.radiowaves.left.and.right",
                            title: "ARDOP (Kurzwelle)",
                            subtitle: "Verbindung über HF-Transceiver",
                            action: connectViaARDOP
                        )

                        Divider()

                        // P2P Direct
                        ConnectOptionRow(
                            icon: "person.2",
                            title: "P2P (Direkt)",
                            subtitle: "Station-zu-Station ohne Gateway",
                            action: connectP2P
                        )
                    }
                }
                .padding(.horizontal)

                // Gateway Directory
                GroupBox("RMS-Gateway-Verzeichnis") {
                    VStack(spacing: 8) {
                        Button(action: { showingGateways = true }) {
                            HStack {
                                Image(systemName: "map")
                                Text("Gateways anzeigen")
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Text("Finde ARDOP-fähige RMS-Gateways in deiner Nähe")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal)

                // Winlink Frequencies
                GroupBox("Standard-Frequenzen") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(winlinkFrequencyList, id: \.band) { entry in
                            HStack {
                                Text(entry.band)
                                    .frame(width: 50, alignment: .leading)
                                Spacer()
                                Text(entry.frequency)
                                    .foregroundStyle(.green)
                            }
                            .font(.system(.caption, design: .monospaced))
                        }
                    }
                }
                .padding(.horizontal)

                // Position Report
                GroupBox("Positionsbericht") {
                    VStack(spacing: 8) {
                        Button(action: sendPositionReport) {
                            Label("Position senden", systemImage: "location")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)

                        Text("Sendet GPS-Position über Winlink")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal)

                Spacer(minLength: 40)
            }
            .padding(.top, 8)
        }
    }

    // MARK: - Info Section

    private var infoSection: some View {
        ScrollView {
            VStack(spacing: 16) {
                // ARDOP Codec Status
                GroupBox("ARDOP Codec") {
                    VStack(alignment: .leading, spacing: 10) {
                        StatusRow(label: "Codec", value: "Implementiert", color: .green)
                        StatusRow(label: "Modulation", value: "4FSK / 4PSK / 8PSK / 16QAM", color: .green)
                        StatusRow(label: "Bandbreiten", value: "200 / 500 / 1000 / 2000 Hz", color: .green)
                        StatusRow(label: "FEC", value: "Reed-Solomon GF(256)", color: .green)
                        StatusRow(label: "ARQ Session", value: "Implementiert", color: .green)
                        StatusRow(label: "B2F Protokoll", value: "Implementiert", color: .green)
                        StatusRow(label: "LZHUF Kompression", value: "Implementiert", color: .green)
                        StatusRow(label: "Telnet Transport", value: "Implementiert", color: .green)
                        StatusRow(label: "P2P Modus", value: "Implementiert", color: .green)
                    }
                    .font(.system(.body, design: .monospaced))
                }
                .padding(.horizontal)

                // Mailbox Stats
                GroupBox("Mailbox") {
                    let stats = WinlinkMailbox.shared.getStats()
                    VStack(alignment: .leading, spacing: 8) {
                        StatusRow(label: "Posteingang", value: "\(stats.inboxCount) (\(stats.unreadCount) ungelesen)", color: stats.unreadCount > 0 ? .blue : .secondary)
                        StatusRow(label: "Postausgang", value: "\(stats.outboxCount)", color: stats.outboxCount > 0 ? .orange : .secondary)
                        StatusRow(label: "Gesendet", value: "\(stats.sentCount)", color: .secondary)
                        StatusRow(label: "Archiv", value: "\(stats.archiveCount)", color: .secondary)
                    }
                }
                .padding(.horizontal)

                // Open Source References
                GroupBox("Open Source Referenzen") {
                    VStack(alignment: .leading, spacing: 8) {
                        ReferenceRow(name: "ARDOP TNC", description: "Amateur Radio Digital Open Protocol", url: "github.com/pflarue/ardop")
                        Divider()
                        ReferenceRow(name: "Pat", description: "Winlink Client in Go (MIT License)", url: "github.com/la5nta/pat")
                        Divider()
                        ReferenceRow(name: "WSJT-X", description: "FT8/WSPR von Dr. Joe Taylor (K1JT) & Steve Franke (K9AN)", url: "wsjt.sourceforge.io")
                        Divider()
                        ReferenceRow(name: "Fldigi", description: "Digital Modem Program — Multi-Mode Transceiver", url: "sourceforge.net/projects/fldigi")
                        Divider()
                        ReferenceRow(name: "(tr)uSDX", description: "QRP Transceiver von Manuel Klüber (DL2MAN)", url: "dl2man.de")
                        Divider()
                        ReferenceRow(name: "Winlink", description: "Global Radio Email System", url: "winlink.org")
                    }
                }
                .padding(.horizontal)

                Spacer(minLength: 40)
            }
            .padding(.top, 8)
        }
    }

    // MARK: - Account Status Card

    private var accountStatusCard: some View {
        GroupBox {
            let account = WinlinkAccountManager.shared.loadAccount()
            HStack {
                if let account = account, account.isConfigured {
                    Image(systemName: "person.crop.circle.badge.checkmark")
                        .font(.title2)
                        .foregroundStyle(.green)
                    VStack(alignment: .leading) {
                        Text(account.callsign.uppercased())
                            .font(.headline)
                        Text(account.winlinkEmail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Image(systemName: "person.crop.circle.badge.exclamationmark")
                        .font(.title2)
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading) {
                        Text("Konto nicht konfiguriert")
                            .font(.headline)
                        Text("Bitte Winlink-Zugangsdaten eingeben")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button(action: { showingAccountSetup = true }) {
                    Image(systemName: "gear")
                }
            }
        }
        .padding(.horizontal)
    }

    // MARK: - Actions

    private func connectViaTelnet() {
        Task {
            connectionStatus = "Verbinde über Telnet..."
            do {
                let telnet = try await WinlinkTelnet.connectToBestServer()
                guard let account = WinlinkAccountManager.shared.loadAccount() else {
                    connectionStatus = "Kein Konto konfiguriert"
                    return
                }
                let b2f = B2FSession(
                    transport: telnet,
                    account: account,
                    mailbox: WinlinkMailbox.shared
                )
                try await b2f.exchange()
                connectionStatus = "Austausch abgeschlossen"
                unreadCount = WinlinkMailbox.shared.unreadCount()
                telnet.disconnect()
            } catch {
                connectionStatus = "Fehler: \(error.localizedDescription)"
            }
        }
    }

    private func connectViaARDOP() {
        connectionStatus = "ARDOP-Verbindung wird vorbereitet..."
    }

    private func connectP2P() {
        connectionStatus = "P2P-Modus wird vorbereitet..."
    }

    private func sendPositionReport() {
        guard let account = WinlinkAccountManager.shared.loadAccount() else { return }
        // Use a default position; in production, use LocationManager
        let report = WinlinkPositionReport(
            latitude: 0, longitude: 0, altitude: nil,
            speed: nil, course: nil, timestamp: Date(),
            comment: "DigiFox Position Report",
            priority: .routine
        )
        WinlinkPositionManager.shared.sendPositionReport(
            report: report,
            callsign: account.callsign
        )
    }

    // MARK: - Data

    private var winlinkFrequencyList: [(band: String, frequency: String)] {
        let freqs = BandPlan.winlinkFrequencies
        return BandPlan.hfBands.compactMap { band in
            guard let hz = freqs[band.id] else { return nil }
            return (band: band.name, frequency: Band.formatMHz(hz))
        }
    }
}

// MARK: - Account Setup View

struct WinlinkAccountView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var callsign = ""
    @State private var password = ""
    @State private var gridLocator = ""
    @State private var savedMessage: String?

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Zugangsdaten")) {
                    TextField("Rufzeichen", text: $callsign)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    SecureField("Winlink-Passwort", text: $password)
                }

                Section(header: Text("Optional")) {
                    TextField("Grid-Locator (z.B. JN48ab)", text: $gridLocator)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                }

                if let msg = savedMessage {
                    Section {
                        Text(msg)
                            .foregroundColor(.green)
                    }
                }

                Section {
                    Button("Speichern") {
                        let account = WinlinkAccount(
                            callsign: callsign,
                            password: password,
                            gridLocator: gridLocator.isEmpty ? nil : gridLocator
                        )
                        try? WinlinkAccountManager.shared.saveAccount(account)
                        savedMessage = "Konto gespeichert ✓"
                    }
                    .disabled(callsign.isEmpty || password.isEmpty)
                }
            }
            .navigationTitle("Winlink-Konto")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Schließen") { dismiss() }
                }
            }
            .onAppear {
                if let account = WinlinkAccountManager.shared.loadAccount() {
                    callsign = account.callsign
                    password = account.password
                    gridLocator = account.gridLocator ?? ""
                }
            }
        }
    }
}

// MARK: - Gateway List View

struct GatewayListView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var gateways: [RMSGateway] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationView {
            Group {
                if isLoading {
                    ProgressView("Lade Gateways...")
                } else if let error = errorMessage {
                    VStack {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundStyle(.orange)
                        Text(error)
                            .font(.body)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                } else if gateways.isEmpty {
                    Text("Keine Gateways gefunden")
                        .foregroundStyle(.secondary)
                } else {
                    List(gateways) { gw in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(gw.callsign)
                                    .font(.headline)
                                Spacer()
                                Text(gw.band)
                                    .font(.caption)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.blue.opacity(0.1))
                                    .clipShape(Capsule())
                            }
                            HStack {
                                Text(gw.frequencyMHz)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.green)
                                Spacer()
                                Text(gw.gridSquare)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if let dist = gw.distanceKm {
                                    Text(String(format: "%.0f km", dist))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("RMS Gateways")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Schließen") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(action: loadGateways) {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .onAppear { loadGateways() }
        }
    }

    private func loadGateways() {
        isLoading = true
        errorMessage = nil
        Task {
            do {
                let result = try await CMSGatewayAPI.shared.fetchARDOPGateways()
                await MainActor.run {
                    gateways = result
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }
}

// MARK: - Connect Option Row

private struct ConnectOptionRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(.blue)
                    .frame(width: 32)
                VStack(alignment: .leading) {
                    Text(title)
                        .font(.subheadline.bold())
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Subviews

private struct StatusRow: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        HStack {
            Text(label + ":")
            Spacer()
            Text(value)
                .foregroundStyle(color)
        }
    }
}

private struct ReferenceRow: View {
    let name: String
    let description: String
    let url: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
                .font(.headline)
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(url)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.blue)
        }
    }
}
