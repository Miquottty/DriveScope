import DriveDomain
import SwiftUI

struct SettingsView: View {
    @Environment(AppLanguage.self) private var appLanguage
    @Environment(\.dismiss) private var dismiss
    // Same key Home reads to start the next session.
    @AppStorage("capturePreset") private var presetRaw = CapturePreset.default.rawValue
    @AppStorage("locationBackend") private var locationBackend = SensorEnvironment.LocationBackend.locationManager.rawValue
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

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: preset.displayName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(preset.summary)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
            Text(verbatim: costLine)
                .font(.hudNumber(size: 11))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.vertical, 4)
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
