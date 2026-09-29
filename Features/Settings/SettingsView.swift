import SwiftUI

struct SettingsView: View {
    @Environment(AppLanguage.self) private var appLanguage
    @Environment(\.dismiss) private var dismiss
    @AppStorage("locationBackend") private var locationBackend = SensorEnvironment.LocationBackend.locationManager.rawValue
    #if DEBUG
    @AppStorage("debugFastWatchdog") private var fastWatchdog = false
    #endif

    var body: some View {
        @Bindable var appLanguage = appLanguage

        NavigationStack {
            Form {
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
