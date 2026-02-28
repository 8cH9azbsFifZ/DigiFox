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

                // USB devices
                Section {
                    HStack {
                        Image(systemName: appState.ioKitAvailable ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(appState.ioKitAvailable ? .green : .red)
                        Text("IOKit USB-Serial")
                        Spacer()
                        Text(appState.ioKitAvailable ? "Available" : "Not available")
                            .foregroundStyle(.secondary)
                    }
                    if appState.usbDevices.isEmpty {
                        HStack {
                            Image(systemName: "usb").foregroundStyle(.gray)
                            Text("No USB device detected").foregroundStyle(.secondary)
                        }
                    } else {
                        ForEach(appState.usbDevices) { device in
                            HStack {
                                Image(systemName: device.isDigirig ? "cable.connector" : device.isTruSDX ? "antenna.radiowaves.left.and.right" : "usb")
                                    .foregroundStyle(device.isDigirig ? .orange : device.isTruSDX ? .green : .blue)
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
                                if device.isTruSDX {
                                    Text("(tr)uSDX").font(.caption)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Capsule().fill(.green.opacity(0.2)))
                                }
                            }
                        }
                    }
                    Button { appState.scanUSBDevices() } label: {
                        HStack { Image(systemName: "arrow.clockwise"); Text("Scan USB devices") }
                    }
                    if appState.radioState.isConnected {
                        Button(role: .destructive) { appState.disconnectRig() } label: {
                            HStack { Image(systemName: "antenna.radiowaves.left.and.right.slash"); Text("Disconnect \(settings.radioProfile.rawValue)") }
                        }
                    } else if appState.hasCompatibleDevice && settings.useHamlib {
                        Button { appState.connectRig() } label: {
                            HStack { Image(systemName: "antenna.radiowaves.left.and.right"); Text("Connect \(settings.radioProfile.rawValue)") }
                        }.tint(.green)
                    }
                } header: {
                    Text("USB Devices")
                } footer: {
                    if !appState.ioKitAvailable {
                        Text("IOKit is not available on this device. USB serial requires iOS with IOKit access (sideload or EU AltStore).")
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

                Section {
                    Picker("Band", selection: Binding(
                        get: { settings.selectedBand },
                        set: { newBand in
                            settings.selectBand(newBand)
                            // Send frequency to rig if connected
                            if appState.radioState.isConnected,
                               let freq = BandPlan.dialFrequency(band: newBand, mode: settings.digitalMode) {
                                appState.setRigFrequency(UInt64(freq))
                            }
                        }
                    )) {
                        ForEach(BandPlan.allBands) { band in
                            Text(band.name).tag(band.id)
                        }
                    }

                    if let ft8 = BandPlan.ft8Frequency(for: settings.selectedBand) {
                        HStack {
                            Image(systemName: "waveform").foregroundStyle(.blue)
                            Text("FT8"); Spacer()
                            Text(Band.formatMHz(ft8))
                                .foregroundStyle(settings.digitalMode == .ft8 ? .primary : .secondary)
                                .fontWeight(settings.digitalMode == .ft8 ? .semibold : .regular)
                        }
                    }
                    if let js8 = BandPlan.js8Frequency(for: settings.selectedBand) {
                        HStack {
                            Image(systemName: "waveform.path").foregroundStyle(.green)
                            Text("JS8Call"); Spacer()
                            Text(Band.formatMHz(js8))
                                .foregroundStyle(settings.digitalMode == .js8 ? .primary : .secondary)
                                .fontWeight(settings.digitalMode == .js8 ? .semibold : .regular)
                        }
                    }
                    if let cw = BandPlan.cwFrequency(for: settings.selectedBand) {
                        HStack {
                            Image(systemName: "bolt.horizontal.fill").foregroundStyle(.orange)
                            Text("CW"); Spacer()
                            Text(Band.formatMHz(cw))
                                .foregroundStyle(settings.digitalMode == .cw ? .primary : .secondary)
                                .fontWeight(settings.digitalMode == .cw ? .semibold : .regular)
                        }
                    }

                    HStack {
                        Text("Dial"); Spacer()
                        Text(Band.formatMHz(settings.dialFrequency))
                            .foregroundStyle(.secondary)
                    }

                    if settings.digitalMode == .js8 {
                        Picker("Speed", selection: $settings.speedRaw) {
                            ForEach(JS8Speed.allCases) { s in Text(s.name).tag(s.rawValue) }
                        }
                    }
                } header: {
                    Text("Band & Frequenz")
                } footer: {
                    Text("Frequenz wird automatisch für FT8/JS8Call gesetzt und per CAT an das Radio gesendet.")
                }

                Section("Audio") {
                    HStack { Text("TX Leistung"); Slider(value: $settings.txPower, in: 0...1) }
                }

                Section("Info") {
                    HStack { Text("Version"); Spacer(); Text("1.0.0").foregroundStyle(.secondary) }
                    HStack { Text("Hamlib"); Spacer(); Text("4.7.1").foregroundStyle(.secondary) }
                    HStack { Text("Rig Models"); Spacer(); Text("\(rigModels.count)").foregroundStyle(.secondary) }
                    Link(destination: URL(string: "https://github.com/gerolfziegenhain/DigiFox")!) {
                        HStack {
                            Image(systemName: "globe")
                            Text("DigiFox auf GitHub")
                            Spacer()
                            Image(systemName: "arrow.up.right.square").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .task {
                if rigModels.isEmpty {
                    let models = await Task.detached { HamlibRig.listModels() }.value
                    rigModels = models
                }
            }
        }
    }

    private var selectedRigName: String {
        if settings.rigModel == 0 { return "Not selected" }
        return rigModels.first { $0.id == settings.rigModel }?.displayName ?? "Model #\(settings.rigModel)"
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
                Button("No rig (disabled)") { selectedModel = 0 }
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
        .searchable(text: $searchText, prompt: "Search rigs...")
        .navigationTitle("Rig Model")
    }
}
