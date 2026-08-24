import Foundation

/// How a limit window's reset is shown: time left, or the wall clock time it happens at.
enum ResetStyle: String, CaseIterable, Identifiable {
    case remaining
    case clock

    var id: String { rawValue }

    /// The labels are examples of the format itself, which explains them better than a name.
    var title: String {
        switch self {
        case .remaining: L10n.s("через 2 ч", "in 2h")
        case .clock: L10n.s("в 18:40", "at 18:40")
        }
    }

    private static let key = "resetStyle"

    static var preference: ResetStyle {
        get { ResetStyle(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .remaining }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }

    var toggled: ResetStyle { self == .remaining ? .clock : .remaining }
}

enum Format {
    /// Costs are computed in USD and converted for display only.
    static func money(_ amountUSD: Double) -> String {
        guard Money.usesRubles else { return usdString(amountUSD) }
        let value = amountUSD * Money.rate
        return grouped(value, fractionDigits: value >= 100 ? 0 : 1) + " ₽"
    }

    private static func usdString(_ value: Double) -> String {
        let digits = value >= 1_000 ? 0 : (value >= 100 ? 1 : 2)
        return "$" + grouped(value, fractionDigits: digits)
    }

    /// Thousands separated by dots, decimals by a comma: 1.234.567,89
    private static func grouped(_ value: Double, fractionDigits: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = "."
        formatter.decimalSeparator = ","
        formatter.usesGroupingSeparator = true
        formatter.minimumFractionDigits = fractionDigits
        formatter.maximumFractionDigits = fractionDigits
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.\(fractionDigits)f", value)
    }

    static func tokens(_ value: Int) -> String {
        let amount = Double(value)
        switch amount {
        case 1e12...: return String(format: "%.1fT", amount / 1e12)
        case 1e9...: return String(format: "%.1fB", amount / 1e9)
        case 1e6...: return String(format: "%.1fM", amount / 1e6)
        case 1e3...: return String(format: "%.0fK", amount / 1e3)
        default: return "\(value)"
        }
    }

    static func percent(_ value: Double) -> String {
        value >= 10 ? String(format: "%.0f%%", value) : String(format: "%.1f%%", value)
    }

    /// Time left until a limit window resets.
    static func resets(_ date: Date?) -> String? {
        guard let date else { return nil }
        let seconds = date.timeIntervalSinceNow
        guard seconds > 0 else { return nil }

        if seconds < 3_600 {
            let minutes = Int(seconds / 60)
            return L10n.s("через \(minutes) мин", "in \(minutes)m")
        }
        if seconds < 86_400 {
            let hours = Int(seconds / 3_600)
            let minutes = Int(seconds.truncatingRemainder(dividingBy: 3_600) / 60)
            if minutes == 0 { return L10n.s("через \(hours) ч", "in \(hours)h") }
            return L10n.s("через \(hours) ч \(minutes) мин", "in \(hours)h \(minutes)m")
        }
        let days = Int(seconds / 86_400)
        return L10n.s("через \(days) дн", "in \(days)d")
    }

    /// A reset rendered in the currently preferred style.
    static func reset(_ date: Date?, style: ResetStyle) -> String? {
        style == .clock ? resetClock(date) : resets(date)
    }

    /// Wall clock time a limit window resets at: "в 18:40", "ср 18:40", "30 авг 23:00".
    /// The weekly windows land days away, so the day is spelled out when it is not today.
    static func resetClock(_ date: Date?) -> String? {
        guard let date, date.timeIntervalSinceNow > 0 else { return nil }

        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = L10n.locale

        if calendar.isDateInToday(date) {
            formatter.dateFormat = "HH:mm"
            return L10n.s("в \(formatter.string(from: date))", "at \(formatter.string(from: date))")
        }
        if date.timeIntervalSinceNow < 6 * 86_400 {
            formatter.dateFormat = "EEE HH:mm"
            return formatter.string(from: date)
        }
        formatter.dateFormat = "d MMM HH:mm"
        return formatter.string(from: date)
    }

    static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}
