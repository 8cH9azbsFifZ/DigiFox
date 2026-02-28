import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var settings: AppSettings
    @State private var rigModels: [HamlibModelInfo] = []
    @State private var searchText = ""

    private var filteredModels: [HamlibModelInfo] {
        if searchText.isEmpty { return rigModels }
        return rigModels.filter { $0.displayName.localizedCaseInsensitiveContains(searchText) }
    }

    private let ft8BandPresets: [(String, Double)] = [
        ("160m", 1_840_000), ("80m", 3_573_000), ("60m", 5_357_000),
        ("40m", 7_074_000), ("30m", 10_136_000), ("20m", 14_074_000),
        ("17m", 18_100_000), ("15m", 21_074_000), ("12m", 24_915_000),
        ("10m", 28_074_000), ("6m", 50_313_000), ("2m", 144_174_000),
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("Station") {
                    HStack {
                        Text("Rufzeichen"); Spacer()
                        TextField("z.B. DL1ABC", text: $settings.callsign)
                            .multilineTextAlignment(.trailing).autocorrectionDisabled()
                            .textInputAutocapitalization(.characters)
                    }
                    HStack {
                        Text("Grid Locator"); Spacer()
                        TextField("z.B. JO31", text: $settings.grid)
                            .multilineTextAlignment(.trailing).autocorrectionDisabled()
                            .textInputAutocapitalization(.characters)
                    }
                }

                Section("Modus") {
                    Picker("Digitalmodus", selection: $settings.digitalModeRaw) {
                        Text("FT8").tag(0)
                        Text("JS8Call").tag(1)
                    }
                    .pickerStyle(.segmented)
                }

                // USB devices
                Section {
                    HStack {
                        Image(systemName: appState.ioKitAvailable ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(appState.ioKitAvailable ? .green : .red)
                        Text("IOKit USB-Serial")
                        Spacer()
                        Text(appState.ioKitAvailable ? "Verfügbar" : "Nicht verfügbar")
                            .foregroundStyle(.secondary)
                    }
                    if appState.usbDevices.isEmpty {
                        HStack {
                            Image(systemName: "usb").foregroundStyle(.gray)
                            Text("Kein USB-Gerät erkannt").foregroundStyle(.secondary)
                        }
                    } else {
                        ForEach(appState.usbDevices) { device in
                            HStack {
                                Image(systemName: device.isDigirig ? "cable.connector" : "usb")
                                    .foregroundStyle(device.isDigirig ? .orange : .blue)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(device.name).font(.subheadline)
                                    Text(device.path).font(.caption2).foregroundStyle(.secondary)
                                    Text("VID: 0x\(String(device.vendorID, radix: 16, uppercase: true))  PID: 0x\(String(device.productID, radix: 16, uppercase: true))")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if device.isDigirig {
                                    Text("Digirig").font(.caption)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Capsule().fill(.orange.opacity(0.2)))
                                }
                            }
                        }
                    }
                    Button { appState.scanUSBDevices() } label: {
                        HStack { Image(systemName: "arrow.clockwise"); Text("USB-Geräte scannen") }
                    }
                    if appState.radioState.isConnected {
                        Button(role: .destructive) { appState.disconnectRig() } label: {
                            HStack { Image(systemName: "antenna.radiowaves.left.and.right.slash"); Text("Rig trennen (\(appState.radioState.rigName))") }
                        }
                    } else if appState.digirigConnected && settings.useHamlib {
                        Button { appState.connectRig() } label: {
                            HStack { Image(systemName: "antenna.radiowaves.left.and.right"); Text("Digirig verbinden") }
                        }.tint(.green)
                    }
                } header: {
                    Text("USB-Geräte")
                } footer: {
                    if !appState.ioKitAvailable {
                        Text("IOKit ist auf diesem Gerät nicht verfügbar. USB-Serial benötigt iOS mit IOKit-Zugriff (Sideload oder EU Alt-Store).")
                    }
                }

                Section("Funkgerät (Hamlib)") {
                    NavigationLink {
                        RigModelPicker(models: filteredModels, selectedModel: $settings.rigModel, searchText: $searchText)
                    } label: {
                        HStack {
                            Text("Rig-Modell"); Spacer()
                            Text(selectedRigName).foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Text("Baudrate"); Spacer()
                        TextField("9600", value: $settings.rigSerialRate, format: .number)
                            .multilineTextAlignment(.trailing).keyboardType(.numberPad)
                    }
                }

                Section("Frequenz") {
                    HStack {
                        Text("Dial (Hz)"); Spacer()
                        TextField("14074000", value: $settings.dialFrequency, format: .number)
                            .multilineTextAlignment(.trailing).keyboardType(.numberPad)
                    }
                    if settings.digitalMode == .ft8 {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(ft8BandPresets, id: \.0) { name, freq in
                                    Button(name) { settings.dialFrequency = freq }
                                        .buttonStyle(.bordered)
                                        .tint(settings.dialFrequency == freq ? .blue : .gray)
                                        .controlSize(.small)
                                }
                            }
                        }
                    }
                    if settings.digitalMode == .js8 {
                        Picker("Geschwindigkeit", selection: $settings.speedRaw) {
                            ForEach(JS8Speed.allCases) { s in Text(s.name).tag(s.rawValue) }
                        }
                    }
                }

                Section("Audio") {
                    HStack { Text("TX Leistung"); Slider(value: $settings.txPower, in: 0...1) }
                }

                if settings.digitalMode == .js8 {
                    Section("Netzwerk (JS8Call Desktop)") {
                        HStack {
                            Text("Host"); Spacer()
                            TextField("localhost", text: $settings.networkHost)
                                .multilineTextAlignment(.trailing).autocorrectionDisabled()
                        }
                        HStack {
                            Text("Port"); Spacer()
                            TextField("2442", value: $settings.networkPort, format: .number)
                                .multilineTextAlignment(.trailing).keyboardType(.numberPad)
                        }
                    }
                }

                Section("Info") {
                    HStack { Text("Version"); Spacer(); Text("1.0.0").foregroundStyle(.secondary) }
                    HStack { Text("Hamlib"); Spacer(); Text("4.7.1").foregroundStyle(.secondary) }
                    HStack { Text("Rig-Modelle"); Spacer(); Text("\(rigModels.count)").foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Einstellungen")
            .task {
                if rigModels.isEmpty {
                    let models = await Task.detached { HamlibRig.listModels() }.value
                    rigModels = models
                }
            }
        }
    }

    private var selectedRigName: String {
        if settings.rigModel == 0 { return "Nicht ausgewählt" }
        return rigModels.first { $0.id == settings.rigModel }?.displayName ?? "Modell #\(settings.rigModel)"
    }
}

struct RigModelPicker: View {
    let models: [HamlibModelInfo]
    @Binding var selectedModel: Int
    @Binding var searchText: String

    private var manufacturers: [String] {
        Array(Set(models.map { $0.manufacturer })).sorted()
    }

    var body: some View {
        List {
            Section {
                Button("Kein Rig (deaktiviert)") { selectedModel = 0 }
                    .foregroundStyle(selectedModel == 0 ? .blue : .primary)
            }
            ForEach(manufacturers, id: \.self) { mfg in
                Section(mfg) {
                    ForEach(models.filter { $0.manufacturer == mfg }) { model in
                        Button {
                            selectedModel = model.id
                        } label: {
                            HStack {
                                Text(model.name)
                                Spacer()
                                if selectedModel == model.id {
                                    Image(systemName: "checkmark").foregroundStyle(.blue)
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                }
            }
        }
        .searchable(text: $searchText, prompt: "Rig suchen...")
        .navigationTitle("Rig-Modell")
    }
}
