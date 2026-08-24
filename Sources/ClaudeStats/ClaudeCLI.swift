import Darwin
import Foundation

/// Talks to the `claude` CLI when the OAuth token in the keychain no longer works.
///
/// Two steps, cheapest first. `refreshLogin()` runs `claude auth status`, which makes the CLI
/// renew its own token; after that the normal request usually succeeds. If it does not,
/// `usage()` drives a real session and reads `/usage` off its screen — the numbers then come
/// from the CLI itself and no token of ours is involved.
enum ClaudeCLI {
    /// Set from the `--dump --cli` debug path to follow what the session is doing.
    nonisolated(unsafe) static var trace: ((String) -> Void)?

    enum Failure: LocalizedError {
        case notInstalled
        case needsLogin
        case timedOut
        case unreadable

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                L10n.s("`claude` не найден в PATH.", "`claude` was not found on the PATH.")
            case .needsLogin:
                L10n.s("Claude Code не авторизован. Запустите `claude` и войдите.",
                       "Claude Code is not signed in. Run `claude` and log in.")
            case .timedOut:
                L10n.s("Claude Code не ответил вовремя.", "Claude Code did not answer in time.")
            case .unreadable:
                L10n.s("Не удалось разобрать вывод `/usage`.", "Could not read the `/usage` output.")
            }
        }
    }

    // MARK: - Step one: let the CLI refresh its own token

    /// Runs `claude auth status`, which reads — and, when needed, renews — the stored login.
    /// Returns true when the CLI reports itself signed in.
    static func refreshLogin() async -> Bool {
        guard let output = await shell("claude auth status --json", timeout: 30) else { return false }
        guard let data = output.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return root["loggedIn"] as? Bool ?? false
    }

    /// Runs one command through a login shell so the CLI is found the same way a terminal finds it.
    private static func shell(_ command: String, timeout: TimeInterval) async -> String? {
        await Task.detached(priority: .utility) { () -> String? in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-l", "-c", command]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice

            do { try process.run() } catch { return nil }

            // `claude` can hang waiting on something interactive; do not wait forever.
            let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)

            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            killer.cancel()

            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)
        }.value
    }

    // MARK: - Step two: read /usage off a real session

    static func usage() async throws -> UsageSnapshot {
        try await Task.detached(priority: .utility) { try readUsage() }.value
    }

    private enum Stage {
        case banner   // waiting for the REPL to come up
        case echo     // typed /usage, waiting for the REPL to echo it back
        case result   // pressed enter, waiting for the usage screen
        case capture  // collecting the screen
    }

    private static func readUsage() throws -> UsageSnapshot {
        let session = try PTY(rows: 40, columns: 100)
        defer { session.terminate() }

        var stage = Stage.banner
        var scan = ""       // trigger text; cleared at every stage change to keep matching cheap
        var captured = ""
        var lastData = Date()
        let deadline = Date(timeIntervalSinceNow: 60)

        while Date() < deadline {
            guard let chunk = session.read(timeout: 0.4) else {
                if stage == .capture, Date().timeIntervalSince(lastData) > 2 { break }
                continue
            }
            lastData = Date()
            let text = strippingEscapes(chunk)
            scan += text
            if stage == .capture { captured += text }

            switch stage {
            case .banner:
                if scan.contains("Welcome to Claude Code")
                    || scan.contains("Select login method")
                    || scan.contains("used with your Claude subscription")
                {
                    throw Failure.needsLogin
                }
                if scan.contains("Quick safety check") {
                    // Started in an empty temp folder, so the trust prompt shows up. Accept it.
                    trace?("trust prompt → enter")
                    session.write("\r")
                    scan = ""
                } else if scan.contains("? for shortcuts") || scan.range(
                    of: "Claude Code v[0-9]", options: .regularExpression) != nil
                {
                    trace?("banner → /usage")
                    session.settle()
                    session.write("/usage")
                    scan = ""
                    stage = .echo
                }
            case .echo:
                // Wait for the REPL to echo the command instead of guessing how long it needs.
                if scan.contains("/usage") {
                    trace?("echo → enter")
                    session.settle()
                    session.write("\r")
                    scan = ""
                    stage = .result
                }
            case .result:
                if scan.contains("Current session") {
                    trace?("usage screen → capturing")
                    captured = scan
                    scan = ""
                    stage = .capture
                    // Nudging the window size makes the CLI repaint every character rather
                    // than skipping the ones it believes are already on screen. It needs a
                    // moment between the two sizes to actually act on the first one.
                    session.resize(columns: 99)
                    Thread.sleep(forTimeInterval: 0.2)
                    session.resize(columns: 100)
                }
            case .capture:
                if scan.count > 4_096 { scan = String(scan.suffix(1_024)) }
            }
        }

        trace?("finished in stage \(stage), \(captured.count) chars captured")
        trace?("tail: " + String((captured.isEmpty ? scan : captured).suffix(400)))
        guard var snapshot = UsageText.snapshot(from: captured) else {
            throw stage == .capture ? Failure.unreadable : Failure.timedOut
        }
        snapshot.source = .cli
        return snapshot
    }

    /// Escape sequences are replaced with a space rather than dropped: the CLI positions text
    /// with cursor moves, so removing them outright glues neighbouring words together.
    private static func strippingEscapes(_ data: Data) -> String {
        let raw = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        return raw
            .replacingOccurrences(
                of: "\u{1B}(?:\\[[^@-~]*[@-~]|\\][^\u{07}]*\u{07}|[^\\[])",
                with: " ",
                options: .regularExpression)
            .replacingOccurrences(of: "[ \t]+", with: " ", options: .regularExpression)
    }
}

/// A pseudo-terminal running one child process. `claude` refuses to start without a terminal,
/// so a plain pipe is not enough.
private final class PTY {
    private var master: Int32 = -1
    private var pid: pid_t = 0

    init(rows: UInt16, columns: UInt16) throws {
        master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0, grantpt(master) == 0, unlockpt(master) == 0,
              let namePointer = ptsname(master)
        else {
            if master >= 0 { close(master) }
            throw ClaudeCLI.Failure.notInstalled
        }
        let slaveName = String(cString: namePointer)
        resize(rows: rows, columns: columns)

        // Start in an empty folder so the session picks up no project context whatsoever.
        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-stats-usage", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: workingDirectory, withIntermediateDirectories: true)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addchdir_np(&actions, workingDirectory.path)
        // Opening the slave after setsid() hands the child its controlling terminal.
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, slaveName, O_RDWR, 0)
        posix_spawn_file_actions_adddup2(&actions, STDIN_FILENO, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, STDIN_FILENO, STDERR_FILENO)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))

        // A login shell so `claude` is found on the PATH the user actually has.
        let arguments = ["/bin/zsh", "-l", "-c", "claude"]
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"

        let argv = arguments.map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for pointer in argv + envp { if let pointer { free(pointer) } }
        }

        var child: pid_t = 0
        let status = posix_spawn(&child, "/bin/zsh", &actions, &attributes, argv, envp)
        guard status == 0 else {
            close(master)
            master = -1
            throw ClaudeCLI.Failure.notInstalled
        }
        pid = child
    }

    func resize(rows: UInt16 = 40, columns: UInt16) {
        guard master >= 0 else { return }
        var size = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(master, TIOCSWINSZ, &size)
    }

    /// Give the REPL a moment to finish drawing before typing into it.
    func settle() {
        Thread.sleep(forTimeInterval: 0.6)
    }

    func write(_ text: String) {
        guard master >= 0 else { return }
        _ = text.withCString { Darwin.write(master, $0, strlen($0)) }
    }

    /// One chunk of output, or nil if nothing arrived within the timeout.
    func read(timeout: TimeInterval) -> Data? {
        guard master >= 0 else { return nil }
        var descriptor = pollfd(fd: master, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, Int32(timeout * 1_000)) > 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: 8_192)
        let count = Darwin.read(master, &buffer, buffer.count)
        guard count > 0 else { return nil }
        return Data(buffer[0..<count])
    }

    func terminate() {
        // Closing the master first hangs up the terminal, which is what normally makes the
        // session quit; the signals below are for when it does not.
        if master >= 0 {
            close(master)
            master = -1
        }
        guard pid > 0 else { return }

        kill(pid, SIGTERM)
        var status: Int32 = 0
        for _ in 0..<20 {
            if waitpid(pid, &status, WNOHANG) != 0 {
                pid = 0
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        kill(pid, SIGKILL)
        waitpid(pid, &status, 0)
        pid = 0
    }

    deinit { terminate() }
}
