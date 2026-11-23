import AppKit
import SwiftUI
import UsageCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let preferences = AppPreferences()
    private lazy var store = UsageMonitorStore(preferences: preferences)
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(
            rootView: PanelView(
                store: store,
                preferences: preferences,
                onOpenSettings: { [weak self] in self?.openSettingsWindow() },
                onQuit: { NSApp.terminate(nil) }
            )
        )

        store.onMenuBarUpdate = { [weak self] in
            self?.updateStatusButton()
        }
        updateStatusButton()
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem.button else { return }

        if let event = NSApp.currentEvent, event.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: "立即刷新", action: #selector(refreshAction), keyEquivalent: "r")
            menu.addItem(withTitle: "设置…", action: #selector(openSettingsAction), keyEquivalent: ",")
            menu.addItem(.separator())
            menu.addItem(withTitle: "退出", action: #selector(quitAction), keyEquivalent: "q")
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
            return
        }

        if popover.isShown {
            popover.performClose(sender)
        } else {
            store.refreshNow()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    @objc private func refreshAction() {
        store.refreshNow()
    }

    @objc private func openSettingsAction() {
        openSettingsWindow()
    }

    @objc private func quitAction() {
        NSApp.terminate(nil)
    }

    private func openSettingsWindow() {
        popover.performClose(nil)
        if let existing = settingsWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(
            rootView: SettingsView(store: store, preferences: preferences)
        )
        let window = NSWindow(contentViewController: hosting)
        window.title = "Antigravity Usage Monitor 设置"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func updateStatusButton() {
        guard let button = statusItem.button else { return }

        let image = NSImage(systemSymbolName: "gauge.with.dots.needle.33percent", accessibilityDescription: "Antigravity Usage")
        image?.isTemplate = true
        button.image = image
        button.imagePosition = .imageLeading

        let columns = store.menuBarColumns()
        if columns.isEmpty {
            button.attributedTitle = NSAttributedString(string: "")
            return
        }

        let attributed = NSMutableAttributedString(string: " ")
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]

        for (index, col) in columns.enumerated() {
            if index > 0 {
                attributed.append(NSAttributedString(string: "  ", attributes: labelAttrs))
            }
            attributed.append(NSAttributedString(string: "\(col.label) ", attributes: labelAttrs))
            let valAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: col.severity.nsColor,
            ]
            attributed.append(NSAttributedString(string: col.value, attributes: valAttrs))
        }

        button.attributedTitle = attributed
    }
}

@main
struct AntigravityUsageMonitorApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
