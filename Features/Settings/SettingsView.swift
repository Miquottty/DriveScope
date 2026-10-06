import DriveDomain
import SwiftUI

struct SettingsView: View {
    @Environment(AppLanguage.self) private var appLanguage
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let permission: LocationPermission
    // Same key Home reads to start the next session.
    @AppStorage("capturePreset") private var presetRaw = CapturePreset.default.rawValue
    @AppStorage("locationBackend") private var locationBackend = SensorEnvironment.LocationBackend.locationManager.rawValue
    @AppStorage(RobustMode.defaultsKey) private var robustMode = false
    @AppStorage("satelliteChime") private var satelliteChime = true
    // Read by `AppModel.archiveAfterDays`; 0 = off.
    @AppStorage("archiveAfterDays") private var archiveAfterDays = 30
    #if DEBUG
    @AppStorage("debugFastWatchdog") private var fastWatchdog = false
    #endif

    var body: some View {
        @Bindable var appLanguage = appLanguage

        NavigationStack {
            Form {
                Section {
                    Picker("Capture preset", selection: $presetRaw) {
                        ForEach(CapturePreset.allCases) { preset in
                            PresetOption(preset: preset).tag(preset.rawValue)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    .accessibilityIdentifier("presetPicker")
                    .listRowBackground(Theme.surface)
                } header: {
                    Text("Capture preset")
                } footer: {
                    Text("Preset is fixed per session. Changes apply to the next START.")
                }
                Section {
                    Picker("Language", selection: $appLanguage.choice) {
                        ForEach(AppLanguage.Choice.allCases) { choice in
                            Group {
                                switch choice {
                                case .system: Text("System")
                                // Language names stay in their own language.
                                case .ja: Text(verbatim: "日本語")
                                case .en: Text(verbatim: "English")
                                }
                            }
                            .tag(choice)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("languagePicker")
                    .listRowBackground(Theme.surface)
                }
                Section {
                    Picker("Location backend", selection: $locationBackend) {
                        Text(verbatim: "CLLocationManager").tag(SensorEnvironment.LocationBackend.locationManager.rawValue)
                        Text(verbatim: "liveUpdates (CLLocationUpdate)").tag(SensorEnvironment.LocationBackend.liveUpdates.rawValue)
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("locationBackendPicker")
                    .listRowBackground(Theme.surface)
                } header: {
                    Text("Recording")
                } footer: {
                    Text("Applies to the next START. Compared in real-car test B.")
                }
                Section {
                    Toggle("Robust mode", isOn: $robustMode)
                        .tint(Theme.accent)
                        .accessibilityIdentifier("robustModeToggle")
                        .listRowBackground(Theme.surface)
                        .onChange(of: robustMode) { _, on in
                            if on { permission.requestAlways() }
                        }
                    if robustMode, !permission.isAlways {
                        Button("Allow location access \"Always\" in Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        }
                        .foregroundStyle(Theme.accent)
                        .listRowBackground(Theme.surface)
                    }
                } footer: {
                    Text("If DriveScope is closed mid-drive (crash, low memory), iOS reopens it in the background and recording continues in the same session within 30 minutes. Needs location access \"Always\".")
                }
                Section {
                    Toggle("Satellite fix chime", isOn: $satelliteChime)
                        .tint(Theme.accent)
                        .accessibilityIdentifier("satelliteChimeToggle")
                        .listRowBackground(Theme.surface)
                } footer: {
                    Text("A short sound and haptic when GPS first locks onto satellites after START. Until then iOS may give only Wi‑Fi positions without speed, so wait for it before setting off. Plays while the HUD is on screen.")
                }
                Section {
                    Picker("Compress old sessions", selection: $archiveAfterDays) {
                        Text("Off").tag(0)
                        ForEach([7, 30, 90], id: \.self) { days in
                            Text("After \(days) days").tag(days)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("archivePicker")
                    .listRowBackground(Theme.surface)
                } header: {
                    Text("Storage")
                } footer: {
                    Text("Lossless (LZFSE). Replay and export work as before. Checked at launch and after each STOP.")
                }
                #if DEBUG
                Section {
                    Toggle("Fast watchdog (÷10)", isOn: $fastWatchdog)
                        .tint(Theme.accent)
                        .accessibilityIdentifier("fastWatchdogToggle")
                        .listRowBackground(Theme.surface)
                } header: {
                    Text("Debug")
                } footer: {
                    Text("Watchdog and dead-man notification timings run ten times faster. Applies to the next START.")
                }
                #endif
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .relocalizing(appLanguage)
    }
}


/// One row of the preset list: name, what it records / loses, and the data / battery cost of an hour of driving.
private struct PresetOption: View {
    let preset: CapturePreset
    @Environment(AppLanguage.self) private var appLanguage
    /// iPad form sheet: the iPad type scale (≥ 15 pt body).
    @Environment(\.iPadSheet) private var iPadSheet

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: preset.displayName)
                .font(.system(size: iPadSheet ? 17 : 16, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(preset.summary)
                .font(.system(size: iPadSheet ? 15 : 12))
                .foregroundStyle(iPadSheet ? Theme.textTertiary : Theme.textSecondary)
            Text(verbatim: costLine)
                .font(.hudNumber(size: iPadSheet ? 14 : 11))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.vertical, iPadSheet ? 6 : 4)
    }

    /// "13.3 MB/h · Screen off ≈ 2.5–3 %/h (estimate)"
    private var costLine: String {
        // Always MB with one decimal, so 0.3 and 27.7 read on the same scale.
        let megabytes = Measurement(value: Double(preset.estimatedBytesPerHour), unit: UnitInformationStorage.bytes)
            .converted(to: .megabytes).value
        let size = megabytes.formatted(.number.precision(.fractionLength(1)).locale(appLanguage.locale))
            + "\u{00A0}" + UnitInformationStorage.megabytes.symbol
        let drain = preset.estimatedScreenOffDrain
        let style = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...1)).locale(appLanguage.locale)
        let range = "\(drain.lowerBound.formatted(style))–\(drain.upperBound.formatted(style))"
        return appLanguage.string("\(size)/h") + " · " + appLanguage.string("Screen off ≈ \(range) %/h (estimate)")
    }
}
