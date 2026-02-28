import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var settings: AppSettings
    @State private var rigModels: [HamlibModelInfo] = []
    @State private var searchText = ""
    @StateObject private var locationManager = LocationManager()

    private var filteredModels: [HamlibModelInfo] {
        if searchText.isEmpty { return rigModels }
        return rigModels.filter { $0.displayName.localizedCaseInsensitiveContains(searchText) }
    }

    private var availableBands: [Band] {
        BandPlan.availableBands(for: settings.digitalMode)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Station") {
                    HStack {
                        Text("Rufzeichen"); Spacer()
                        TextField("e.g. DL1ABC", text: $settings.callsign)
                            .multilineTextAlignment(.trailing).autocorrectionDisabled()
                            .textInputAutocapitalization(.characters)
                    }
                    HStack {
                        Text("Grid Locator"); Spacer()
                        TextField("e.g. JO31", text: $settings.grid)
                            .multilineTextAlignment(.trailing).autocorrectionDisabled()
                            .textInputAutocapitalization(.characters)
                        Button {
                            locationManager.requestGrid { grid in
                                if let grid { settings.grid = String(grid.prefix(4)).uppercased() }
                            }
                        } label: {
                            if locationManager.isLocating {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "location.fill")
                            }
                        }
                        .disabled(locationManager.isLocating)
                    }
                    if let error = locationManager.error {
                        Text(error).font(.caption).foregroundStyle(.red)
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

                Section("Radio Profile") {
                    Picker("Connection", selection: Binding(
                        get: { settings.radioProfile },
                        set: { settings.radioProfile = $0 }
                    )) {
                        ForEach(RadioProfile.allCases) { profile in
                            Text(profile.rawValue).tag(profile)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(settings.radioProfile.description)
                        .font(.caption).foregroundStyle(.secondary)
                    if settings.radioProfile == .trusdx {
                        HStack {
                            Image(systemName: "info.circle").foregroundStyle(.blue)
                            Text("Baud rate auto-set to 115200 for CAT_STREAMING")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Rig (Hamlib)") {
                    NavigationLink {
                        RigModelPicker(models: filteredModels, selectedModel: $settings.rigModel, searchText: $searchText)
                    } label: {
                        HStack {
                            Text("Rig Model"); Spacer()
                            Text(selectedRigName).foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Text("Baud Rate"); Spacer()
                        TextField("9600", value: $settings.rigSerialRate, format: .number)
                            .multilineTextAlignment(.trailing).keyboardType(.numberPad)
                    }
                    .disabled(settings.radioProfile == .trusdx)
                }

                Section("Frequency") {
                    HStack {
                        Text("Band"); Spacer()
                        Picker("Band", selection: Binding(
                            get: { settings.selectedBand },
                            set: { settings.selectBand($0) }
                        )) {
                            ForEach(availableBands) { band in
                                Text(band.name).tag(band.id)
                            }
                        }
                        .labelsHidden()
                    }
                    HStack {
                        Text("Dial (Hz)"); Spacer()
                        TextField("14074000", value: $settings.dialFrequency, format: .number)
                            .multilineTextAlignment(.trailing).keyboardType(.numberPad)
                    }
                    if let freq = BandPlan.dialFrequency(band: settings.selectedBand, mode: settings.digitalMode) {
                        HStack {
                            Text("Standard \(settings.digitalMode.name)"); Spacer()
                            Text(Band.formatMHz(freq)).foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(availableBands) { band in
                                Button(band.name) { settings.selectBand(band.id) }
                                    .buttonStyle(.bordered)
                                    .tint(settings.selectedBand == band.id ? .blue : .gray)
                                    .controlSize(.small)
                            }
                        }
                    }
                    if settings.digitalMode == .js8 {
                        Picker("Speed", selection: $settings.speedRaw) {
                            ForEach(JS8Speed.allCases) { s in Text(s.name).tag(s.rawValue) }
                        }
                    }
                }

                Section("Audio") {
                    HStack { Text("TX Leistung"); Slider(value: $settings.txPower, in: 0...1) }
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
