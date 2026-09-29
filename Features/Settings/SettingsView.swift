import SwiftUI

struct SettingsView: View {
    @Environment(AppLanguage.self) private var appLanguage
    @Environment(\.dismiss) private var dismiss

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
