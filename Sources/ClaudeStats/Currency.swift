import Foundation

enum Currency: String, CaseIterable, Identifiable {
    case system
    case usd
    case rub

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: L10n.s("Авто", "Auto")
        case .usd: "$"
        case .rub: "₽"
        }
    }
}

/// Currency preference plus a USD→RUB rate refreshed once a day.
enum Money {
    private static let currencyKey = "currency"
    private static let rateKey = "usdRubRate"
    private static let rateDateKey = "usdRubRateDate"

    static var preference: Currency {
        get { Currency(rawValue: UserDefaults.standard.string(forKey: currencyKey) ?? "") ?? .system }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: currencyKey) }
    }

    static var usesRubles: Bool {
        switch preference {
        case .usd: false
        case .rub: true
        case .system: L10n.isRussian
        }
    }

    /// Last known rate; the bundled default only matters before the first fetch.
    static var rate: Double {
        let stored = UserDefaults.standard.double(forKey: rateKey)
        return stored > 0 ? stored : 80
    }

    private static var rateIsFresh: Bool {
        let fetched = UserDefaults.standard.double(forKey: rateDateKey)
        return fetched > 0 && Date().timeIntervalSince1970 - fetched < 86_400
    }

    /// Central Bank of Russia publishes daily rates without an API key.
    private static let primary = URL(string: "https://www.cbr-xml-daily.ru/daily_json.js")!
    private static let fallback = URL(string: "https://open.er-api.com/v6/latest/USD")!

    static func refreshRateIfNeeded() async {
        guard !rateIsFresh else { return }
        guard let value = await fetchRate() else { return }
        UserDefaults.standard.set(value, forKey: rateKey)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: rateDateKey)
    }

    private static func fetchRate() async -> Double? {
        if let data = try? await URLSession.shared.data(from: primary).0,
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let valutes = root["Valute"] as? [String: Any],
           let usd = valutes["USD"] as? [String: Any],
           let value = usd["Value"] as? Double, value > 0
        {
            return value
        }
        if let data = try? await URLSession.shared.data(from: fallback).0,
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let rates = root["rates"] as? [String: Any],
           let value = rates["RUB"] as? Double, value > 0
        {
            return value
        }
        return nil
    }
}
