import Foundation

/// Claude Code OAuth token. Read-only: the keychain item belongs to the CLI,
/// so we never refresh or rewrite it.
struct ClaudeCredentials {
    let accessToken: String
    let expiresAt: Date?
    let subscriptionType: String?

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt <= Date()
    }

    private static let keychainService = "Claude Code-credentials"

    enum LoadError: LocalizedError {
        case notFound
        case denied
        /// Access was denied before; wait for an explicit Refresh.
        case waitingForManualRetry

        var errorDescription: String? {
            switch self {
            case .notFound:
                L10n.s("Не найден вход в Claude Code. Запустите `claude` и авторизуйтесь.",
                       "No Claude Code login found. Run `claude` and sign in.")
            case .denied:
                L10n.s("Нет доступа к связке ключей. Нажмите «Обновить» и выберите «Всегда разрешать».",
                       "No keychain access. Hit Refresh and choose Always Allow.")
            case .waitingForManualRetry:
                L10n.s("Нет доступа к связке ключей. Нажмите «Обновить», чтобы запросить его снова.",
                       "No keychain access. Hit Refresh to ask again.")
            }
        }
    }

    static func load() throws -> ClaudeCredentials {
        if let fromFile = loadFromFile() { return fromFile }
        guard let data = readKeychainViaSecurityTool() else { throw LoadError.denied }
        guard let parsed = parse(data) else { throw LoadError.notFound }
        return parsed
    }

    private static func loadFromFile() -> ClaudeCredentials? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parse(data)
    }

    /// Read through `/usr/bin/security` rather than the Security framework directly.
    /// Its keychain ACL entry survives our rebuilds, so the approval prompt appears once
    /// instead of after every new signature.
    private static func readKeychainViaSecurityTool() -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", keychainService, "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, !data.isEmpty else { return nil }
        return data
    }

    private static func parse(_ data: Data) -> ClaudeCredentials? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let oauth = (root["claudeAiOauth"] as? [String: Any]) ?? root
        guard let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        let expires = (oauth["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        return ClaudeCredentials(
            accessToken: token,
            expiresAt: expires,
            subscriptionType: oauth["subscriptionType"] as? String)
    }
}

/// Keeps the token in memory so the keychain is queried once per launch instead of
/// on every refresh. After a denial, only a user-initiated refresh retries.
final class CredentialsProvider {
    static let shared = CredentialsProvider()

    private let lock = NSLock()
    private var cached: ClaudeCredentials?
    private var accessDenied = false

    /// Drops the cached token so the next read goes back to the keychain — used after the
    /// CLI has been asked to refresh its login.
    func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        cached = nil
    }

    func credentials(userInitiated: Bool) throws -> ClaudeCredentials {
        lock.lock()
        defer { lock.unlock() }

        if let cached, !cached.isExpired { return cached }
        if accessDenied, !userInitiated { throw ClaudeCredentials.LoadError.waitingForManualRetry }

        do {
            let loaded = try ClaudeCredentials.load()
            cached = loaded
            accessDenied = false
            return loaded
        } catch ClaudeCredentials.LoadError.denied {
            accessDenied = true
            throw ClaudeCredentials.LoadError.denied
        }
    }
}
