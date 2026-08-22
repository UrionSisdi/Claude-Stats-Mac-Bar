import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = StatsModel()
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var timer: Timer?
    private var cancellable: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        LaunchAtLogin.syncOnLaunch()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "asterisk",
            accessibilityDescription: "Claude Stats")
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)

        // A popover rather than an NSMenu: menus swallow clicks meant for controls.
        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = NSHostingController(rootView: MenuView(
            model: model,
            onRefresh: { [weak self] in self?.model.refresh(userInitiated: true) },
            onQuit: { NSApp.terminate(nil) }))

        cancellable = model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.updateTitle() }

        model.refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.model.refresh() }
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            model.refresh()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // Without activation the popover never becomes key and swallows control clicks.
            NSApp.activate(ignoringOtherApps: true)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func updateTitle() {
        let percent = model.snapshot?.session?.percent
        statusItem.button?.title = percent.map { " " + Format.percent($0) } ?? ""
    }
}
