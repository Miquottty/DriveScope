import Observation
import SwiftUI

/// In-app language (PLAN §13). Switches instantly: SwiftUI reads `locale` through the environment, and non-View
/// code resolves strings through `string(_:)`. `AppleLanguages` is deliberately not touched (needs a restart).
@Observable
@MainActor
final class AppLanguage {
    enum Choice: String, CaseIterable, Identifiable {
        case system, ja, en
        var id: String { rawValue }
    }

    private static let defaultsKey = "appLanguage"

    var choice: Choice {
        didSet { UserDefaults.standard.set(choice.rawValue, forKey: Self.defaultsKey) }
    }

    init() {
        let stored = UserDefaults.standard.string(forKey: Self.defaultsKey)
        choice = stored.flatMap(Choice.init(rawValue:)) ?? .system
    }

    var languageCode: String {
        switch choice {
        case .ja: "ja"
        case .en: "en"
        case .system: Locale.preferredLanguages.first?.hasPrefix("ja") == true ? "ja" : "en"
        }
    }

    var locale: Locale { Locale(identifier: languageCode) }

    var bundle: Bundle {
        Bundle.main.path(forResource: languageCode, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
    }

    /// For non-View code (notifications, export labels, auto titles).
    func string(_ key: String.LocalizationValue) -> String {
        String(localized: key, bundle: bundle, locale: locale)
    }
}

extension View {
    /// UIKit-backed chrome (navigation titles, toolbar items) caches its text; rebuilding the stack on a language
    /// change makes it pick up the new locale. Apply to every `NavigationStack`.
    func relocalizing(_ appLanguage: AppLanguage) -> some View {
        id(appLanguage.languageCode)
    }
}
