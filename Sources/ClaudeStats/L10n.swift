import Foundation

enum Language: String, CaseIterable, Identifiable {
    case system
    case english
    case russian

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: L10n.s("Авто", "Auto")
        case .english: "EN"
        case .russian: "RU"
        }
    }
}

/// Two-language UI strings, picked inline at each call site.
enum L10n {
    private static let key = "language"

    static var preference: Language {
        get { Language(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .system }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }

    static var isRussian: Bool {
        switch preference {
        case .russian: true
        case .english: false
        case .system: Locale.preferredLanguages.first?.hasPrefix("ru") ?? false
        }
    }

    static var locale: Locale { Locale(identifier: isRussian ? "ru_RU" : "en_US") }

    static func s(_ russian: String, _ english: String) -> String {
        isRussian ? russian : english
    }
}
