import Foundation

enum DebugDump {
    static func run() {
        // `--cli` exercises the CLI fallback on its own; local scanning would only slow it down.
        if CommandLine.arguments.contains("--cli") {
            runCLI()
            return
        }

        let started = Date()
        var cache = ScanCache.load()
        let records = LocalUsage.scan(cache: &cache)
        cache.save()
        print("Records: \(records.count), scan took \(String(format: "%.2f", -started.timeIntervalSinceNow))s")

        let now = Date().timeIntervalSince1970
        let periods: [(String, Double?)] = [
            ("Today", Calendar.current.startOfDay(for: Date()).timeIntervalSince1970),
            ("7 days", now - 7 * 86_400),
            ("30 days", now - 30 * 86_400),
            ("All time", nil),
        ]
        for (title, since) in periods {
            let stats = LocalUsage.stats(records, since: since)
            let t = stats.tokens
            print("\(title): \(Format.money(stats.cost)) · \(Format.tokens(t.total)) tokens · \(stats.messages) messages")
            print("   in \(t.input) · out \(t.output) · cacheRead \(t.cacheRead) · write5m \(t.cacheWrite5m) · write1h \(t.cacheWrite1h)")
            for item in stats.byModel.prefix(5) {
                print("   \(Pricing.displayName(item.model)): \(Format.money(item.cost)) · \(Format.tokens(item.tokens.total))")
            }
        }
        for (label, stats) in LocalUsage.monthly(records, limit: 12) {
            print("\(label): \(Format.money(stats.cost)) · \(Format.tokens(stats.tokens.total))")
        }

        guard CommandLine.arguments.contains("--limits") else { return }
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            do {
                let credentials = try CredentialsProvider.shared.credentials(userInitiated: true)
                let snapshot = try await UsageAPI.fetch(accessToken: credentials.accessToken)
                for window in snapshot.windows {
                    print("\(window.title): \(Format.percent(window.percent)) \(Format.resets(window.resetsAt) ?? "")")
                }
            } catch {
                print("Limits: \(error.localizedDescription)")
            }
            semaphore.signal()
        }
        semaphore.wait()
    }

    /// Exercises the CLI fallback end to end: the cheap token refresh first, then a real
    /// session whose `/usage` screen is parsed.
    private static func runCLI() {
        ClaudeCLI.trace = { print("  · \($0)") }
        let started = Date()
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            print("claude auth status → loggedIn \(await ClaudeCLI.refreshLogin())")
            do {
                let snapshot = try await ClaudeCLI.usage()
                for window in snapshot.windows {
                    let resets = window.resetsAt
                    print("\(window.title): \(Format.percent(window.percent)) · "
                        + "\(Format.resets(resets) ?? "?") · "
                        + "\(resets.map { Format.resetClock($0) ?? "?" } ?? "no reset")")
                }
            } catch {
                print("failed: \(error.localizedDescription)")
            }
            print(String(format: "took %.1fs", -started.timeIntervalSinceNow))
            semaphore.signal()
        }
        semaphore.wait()
    }
}
