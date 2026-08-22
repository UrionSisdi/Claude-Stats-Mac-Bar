import AppKit

// Debug mode: `ClaudeStats --dump` prints the same numbers to the terminal.
if CommandLine.arguments.contains("--dump") {
    DebugDump.run()
    exit(0)
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    // Keep the delegate alive for the lifetime of the process.
    objc_setAssociatedObject(application, "ClaudeStatsDelegate", delegate, .OBJC_ASSOCIATION_RETAIN)
    application.run()
}
