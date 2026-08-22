import Foundation
import SwiftUI

@MainActor
final class StatsModel: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var usageError: String?
    @Published private(set) var today = PeriodStats()
    @Published private(set) var week = PeriodStats()
    @Published private(set) var month = PeriodStats()
    @Published private(set) var allTime = PeriodStats()
    @Published private(set) var monthly: [(label: String, stats: PeriodStats)] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var language = L10n.preference
    @Published private(set) var currency = Money.preference
    @Published var launchAtLogin = LaunchAtLogin.isEnabled

    private var records: [UsageRecord] = []
    private var lastUsageFetch: Date?
    private var rateLimitedUntil: Date?

    /// The usage endpoint is shared with the CLI and rate limits aggressively,
    /// so background refreshes stay well apart.
    private let minimumFetchInterval: TimeInterval = 300

    /// `userInitiated` marks a refresh triggered by the button: only that one may
    /// prompt the keychain again after access was denied.
    func refresh(userInitiated: Bool = false) {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task {
            await Money.refreshRateIfNeeded()
            async let usage: Void = refreshUsage(userInitiated: userInitiated)
            async let local: Void = refreshLocal()
            _ = await (usage, local)
            isRefreshing = false
        }
    }

    private func refreshUsage(userInitiated: Bool) async {
        if let until = rateLimitedUntil, until > Date() {
            if snapshot == nil { snapshot = UsageSnapshot.loadCached() }
            return
        }
        if !userInitiated, let last = lastUsageFetch,
           Date().timeIntervalSince(last) < minimumFetchInterval
        {
            return
        }

        do {
            let credentials = try CredentialsProvider.shared.credentials(userInitiated: userInitiated)
            lastUsageFetch = Date()
            let fresh = try await UsageAPI.fetch(accessToken: credentials.accessToken)
            fresh.cache()
            snapshot = fresh
            rateLimitedUntil = nil
            usageError = nil
        } catch let error as UsageAPIError {
            if case let .rateLimited(retryAfter) = error {
                rateLimitedUntil = retryAfter ?? Date(timeIntervalSinceNow: 600)
            }
            if snapshot == nil { snapshot = UsageSnapshot.loadCached() }
            usageError = error.localizedDescription
        } catch {
            if snapshot == nil { snapshot = UsageSnapshot.loadCached() }
            usageError = error.localizedDescription
        }
    }

    private func refreshLocal() async {
        let scanned: [UsageRecord] = await Task.detached(priority: .utility) {
            var cache = ScanCache.load()
            let records = LocalUsage.scan(cache: &cache)
            cache.save()
            return records
        }.value

        records = scanned
        recompute()
    }

    private func recompute() {
        let startOfDay = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        let now = Date().timeIntervalSince1970

        today = LocalUsage.stats(records, since: startOfDay)
        week = LocalUsage.stats(records, since: now - 7 * 86_400)
        month = LocalUsage.stats(records, since: now - 30 * 86_400)
        allTime = LocalUsage.stats(records, since: nil)
        monthly = LocalUsage.monthly(records, limit: 12)
    }

    func toggleLaunchAtLogin() {
        LaunchAtLogin.set(!launchAtLogin)
        launchAtLogin = LaunchAtLogin.isEnabled
    }

    func setLanguage(_ value: Language) {
        L10n.preference = value
        language = value
        recompute()
    }

    func setCurrency(_ value: Currency) {
        Money.preference = value
        currency = value
        recompute()
    }
}
