import Foundation

/// One subscription limit window: the 5-hour session, the weekly cap, or a
/// weekly cap scoped to a single model.
struct UsageWindow: Codable, Identifiable {
    enum Kind: String, Codable { case session, weekly }

    let kind: Kind
    /// Model the window is scoped to; `nil` means all models.
    let model: String?
    let percent: Double
    let resetsAt: Date?

    var id: String { kind.rawValue + (model ?? "") }

    var title: String {
        let base = kind == .session
            ? L10n.s("Сессия · 5 ч", "Session · 5h")
            : L10n.s("Неделя", "Week")
        if let model { return "\(base) · \(model)" }
        return kind == .session ? base : L10n.s("Неделя · всё", "Week · all")
    }
}

struct UsageSnapshot: Codable {
    var windows: [UsageWindow] = []
    var extraUsedCredits: Double?
    var extraLimit: Double?
    var fetchedAt = Date()

    var session: UsageWindow? { windows.first { $0.kind == .session && $0.model == nil } }

    static let cacheURL = ScanCache.url.deletingLastPathComponent()
        .appendingPathComponent("usage-snapshot.json")

    static func loadCached() -> UsageSnapshot? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? JSONDecoder().decode(UsageSnapshot.self, from: data)
    }

    func cache() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: Self.cacheURL, options: .atomic)
    }
}

enum UsageAPIError: LocalizedError {
    case unauthorized
    case rateLimited(retryAfter: Date?)
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            L10n.s("Токен устарел. Запустите `claude` — он обновит вход.",
                   "Token expired. Run `claude` to refresh the login.")
        case let .rateLimited(retryAfter):
            if let wait = Format.resets(retryAfter) {
                L10n.s("Anthropic ограничил запросы, повтор \(wait).",
                       "Anthropic rate limited us, retrying \(wait).")
            } else {
                L10n.s("Anthropic ограничил запросы. Повторим через несколько минут.",
                       "Anthropic rate limited us. Retrying in a few minutes.")
            }
        case let .http(code):
            L10n.s("Ошибка сети: HTTP \(code)", "Network error: HTTP \(code)")
        }
    }
}

enum UsageAPI {
    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    static func fetch(accessToken: String) async throws -> UsageSnapshot {
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 20
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/2.1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        switch http?.statusCode ?? 0 {
        case 200: return decode(data)
        case 401, 403: throw UsageAPIError.unauthorized
        case 429: throw UsageAPIError.rateLimited(retryAfter: retryAfter(http))
        case let code: throw UsageAPIError.http(code)
        }
    }

    private static func retryAfter(_ response: HTTPURLResponse?) -> Date? {
        guard let raw = response?.value(forHTTPHeaderField: "Retry-After"),
              let seconds = TimeInterval(raw.trimmingCharacters(in: .whitespaces))
        else { return nil }
        return Date(timeIntervalSinceNow: seconds)
    }

    static func decode(_ data: Data) -> UsageSnapshot {
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        var snapshot = UsageSnapshot()

        func window(_ key: String, kind: UsageWindow.Kind, model: String?) {
            guard let raw = root[key] as? [String: Any],
                  let percent = raw["utilization"] as? Double
            else { return }
            snapshot.windows.append(UsageWindow(
                kind: kind,
                model: model,
                percent: percent,
                resetsAt: date(raw["resets_at"] as? String)))
        }

        window("five_hour", kind: .session, model: nil)
        window("seven_day", kind: .weekly, model: nil)
        window("seven_day_opus", kind: .weekly, model: "Opus")
        window("seven_day_sonnet", kind: .weekly, model: "Sonnet")

        // Newer shape: a flat list where weekly windows name the model they scope to.
        for entry in root["limits"] as? [[String: Any]] ?? [] {
            guard let percent = entry["percent"] as? Double else { continue }
            if let active = entry["is_active"] as? Bool, !active { continue }
            let scope = entry["scope"] as? [String: Any]
            let scopedModel = scope?["model"] as? [String: Any]
            let name = (scopedModel?["display_name"] as? String) ?? (scopedModel?["id"] as? String)
            let kind: UsageWindow.Kind = (entry["group"] as? String) == "five_hour" ? .session : .weekly
            let candidate = UsageWindow(
                kind: kind,
                model: name,
                percent: percent,
                resetsAt: date(entry["resets_at"] as? String))
            guard !snapshot.windows.contains(where: { $0.id == candidate.id }) else { continue }
            snapshot.windows.append(candidate)
        }

        if let extra = root["extra_usage"] as? [String: Any], extra["is_enabled"] as? Bool == true {
            snapshot.extraUsedCredits = extra["used_credits"] as? Double
            snapshot.extraLimit = extra["monthly_limit"] as? Double
        }
        return snapshot
    }

    private static func date(_ string: String?) -> Date? {
        guard let string else { return nil }
        return LocalUsage.parseTimestamp(string).map { Date(timeIntervalSince1970: $0) }
    }
}
