import SwiftUI

/// Winlink placeholder view — prepared for future Pat integration.
///
/// This tab provides information about planned Winlink email-over-radio
/// capabilities using the ARDOP codec and the Pat Winlink client protocol.
///
/// Open Source Referenzen:
///   - ARDOP TNC: https://github.com/pflarue/ardop
///   - Pat Winlink Client: https://github.com/la5nta/pat (Go, MIT License)
///   - Winlink: https://winlink.org
struct WinlinkView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {

                    // MARK: - Header
                    VStack(spacing: 8) {
                        Image(systemName: "envelope.badge.shield.half.filled")
                            .font(.system(size: 56))
                            .foregroundStyle(.blue)
                        Text("Winlink")
                            .font(.largeTitle.bold())
                        Text("E-Mail über Kurzwelle")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 20)

                    // MARK: - Status
                    GroupBox {
                        VStack(spacing: 12) {
                            Label("Coming Soon", systemImage: "hammer.fill")
                                .font(.title3.bold())
                                .foregroundStyle(.orange)

                            Text("Winlink-Funktionalität wird in einer zukünftigen Version integriert. Der ARDOP-Codec ist bereits implementiert.")
                                .font(.body)
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.secondary)
                        }
                        .padding()
                    }
                    .padding(.horizontal)

                    // MARK: - ARDOP Codec Status
                    GroupBox("ARDOP Codec") {
                        VStack(alignment: .leading, spacing: 10) {
                            StatusRow(label: "Codec", value: "Implementiert", color: .green)
                            StatusRow(label: "Modulation", value: "4FSK / 4PSK / 8PSK / 16QAM", color: .green)
                            StatusRow(label: "Bandbreiten", value: "200 / 500 / 1000 / 2000 Hz", color: .green)
                            StatusRow(label: "FEC", value: "Reed-Solomon GF(256)", color: .green)
                            StatusRow(label: "ARQ Session", value: "Geplant", color: .orange)
                        }
                        .font(.system(.body, design: .monospaced))
                    }
                    .padding(.horizontal)

                    // MARK: - Planned Features
                    GroupBox("Geplante Funktionen") {
                        VStack(alignment: .leading, spacing: 10) {
                            FeatureRow(icon: "envelope", text: "E-Mail senden & empfangen über HF")
                            FeatureRow(icon: "antenna.radiowaves.left.and.right", text: "ARDOP ARQ-Verbindung zu RMS-Gateways")
                            FeatureRow(icon: "list.bullet", text: "RMS-Gateway-Verzeichnis (CMS)")
                            FeatureRow(icon: "arrow.triangle.2.circlepath", text: "Automatische Frequenzwahl")
                            FeatureRow(icon: "person.crop.circle.badge.checkmark", text: "Winlink-Kontoverwaltung")
                            FeatureRow(icon: "doc.text", text: "Formular-Unterstützung (ICS 213 etc.)")
                        }
                    }
                    .padding(.horizontal)

                    // MARK: - Winlink Frequencies
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

                    // MARK: - Open Source References
                    GroupBox("Open Source") {
                        VStack(alignment: .leading, spacing: 8) {
                            ReferenceRow(
                                name: "ARDOP TNC",
                                description: "Amateur Radio Digital Open Protocol",
                                url: "github.com/pflarue/ardop"
                            )
                            Divider()
                            ReferenceRow(
                                name: "Pat",
                                description: "Winlink Client in Go (MIT License)",
                                url: "github.com/la5nta/pat"
                            )
                            Divider()
                            ReferenceRow(
                                name: "WSJT-X",
                                description: "FT8/WSPR von Dr. Joe Taylor (K1JT) & Steve Franke (K9AN)",
                                url: "wsjt.sourceforge.io"
                            )
                            Divider()
                            ReferenceRow(
                                name: "Fldigi",
                                description: "Digital Modem Program — Multi-Mode Transceiver",
                                url: "sourceforge.net/projects/fldigi"
                            )
                            Divider()
                            ReferenceRow(
                                name: "(tr)uSDX",
                                description: "QRP Transceiver von Manuel Klüber (DL2MAN)",
                                url: "dl2man.de"
                            )
                            Divider()
                            ReferenceRow(
                                name: "Winlink",
                                description: "Global Radio Email System",
                                url: "winlink.org"
                            )
                        }
                    }
                    .padding(.horizontal)

                    Spacer(minLength: 40)
                }
            }
            .navigationTitle("Winlink")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { StatusToolbar() }
        }
    }

    // MARK: - Frequency Data

    private var winlinkFrequencyList: [(band: String, frequency: String)] {
        let freqs = BandPlan.winlinkFrequencies
        return BandPlan.hfBands.compactMap { band in
            guard let hz = freqs[band.id] else { return nil }
            return (band: band.name, frequency: Band.formatMHz(hz))
        }
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

private struct FeatureRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.blue)
                .frame(width: 24)
            Text(text)
                .font(.body)
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
