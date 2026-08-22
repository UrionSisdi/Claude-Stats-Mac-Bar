import Foundation

/// Price per 1M tokens in USD, as if the traffic went through the plain API.
struct ModelPrice {
    let input: Double
    let output: Double
    let cacheRead: Double
    let cacheWrite5m: Double
    /// 1-hour cache writes cost 2x the base input price.
    var cacheWrite1h: Double { input * 2 }
}

enum Pricing {
    static let table: [String: ModelPrice] = [
        "claude-opus-5": ModelPrice(input: 5, output: 25, cacheRead: 0.5, cacheWrite5m: 6.25),
        "claude-sonnet-5": ModelPrice(input: 2, output: 10, cacheRead: 0.2, cacheWrite5m: 2.5),
        "claude-fable-5": ModelPrice(input: 10, output: 50, cacheRead: 1, cacheWrite5m: 12.5),
        "claude-haiku-4-5": ModelPrice(input: 1, output: 5, cacheRead: 0.1, cacheWrite5m: 1.25),
        "claude-opus-4-5": ModelPrice(input: 5, output: 25, cacheRead: 0.5, cacheWrite5m: 6.25),
        "claude-opus-4-6": ModelPrice(input: 5, output: 25, cacheRead: 0.5, cacheWrite5m: 6.25),
        "claude-opus-4-1": ModelPrice(input: 15, output: 75, cacheRead: 1.5, cacheWrite5m: 18.75),
        "claude-opus-4": ModelPrice(input: 15, output: 75, cacheRead: 1.5, cacheWrite5m: 18.75),
        "claude-sonnet-4-5": ModelPrice(input: 3, output: 15, cacheRead: 0.3, cacheWrite5m: 3.75),
        "claude-sonnet-4-6": ModelPrice(input: 3, output: 15, cacheRead: 0.3, cacheWrite5m: 3.75),
        "claude-sonnet-4": ModelPrice(input: 3, output: 15, cacheRead: 0.3, cacheWrite5m: 3.75),
    ]

    /// Normalizes `claude-opus-5-20260101` and bare `opus` to a known key.
    static func price(for model: String) -> ModelPrice? {
        if let exact = table[model] { return exact }
        let short = ["opus": "claude-opus-5", "sonnet": "claude-sonnet-5", "haiku": "claude-haiku-4-5"]
        if let mapped = short[model], let price = table[mapped] { return price }
        // Drop the dated suffix piece by piece.
        var parts = model.split(separator: "-").map(String.init)
        while parts.count > 1 {
            parts.removeLast()
            if let price = table[parts.joined(separator: "-")] { return price }
        }
        return nil
    }

    static func cost(_ t: TokenTotals, model: String) -> Double {
        guard let p = price(for: model) else { return 0 }
        return (Double(t.input) * p.input
            + Double(t.output) * p.output
            + Double(t.cacheRead) * p.cacheRead
            + Double(t.cacheWrite5m) * p.cacheWrite5m
            + Double(t.cacheWrite1h) * p.cacheWrite1h) / 1_000_000
    }

    /// Short menu label: `claude-opus-5` becomes `Opus 5`.
    static func displayName(_ model: String) -> String {
        var name = model
        if name.hasPrefix("claude-") { name.removeFirst("claude-".count) }
        let parts = name.split(separator: "-").map(String.init)
        guard let family = parts.first else { return model }
        let version = parts.dropFirst().prefix { $0.allSatisfy(\.isNumber) }.joined(separator: ".")
        let capitalized = family.prefix(1).uppercased() + family.dropFirst()
        return version.isEmpty ? capitalized : "\(capitalized) \(version)"
    }
}
