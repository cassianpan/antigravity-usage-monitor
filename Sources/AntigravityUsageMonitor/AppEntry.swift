import AppKit
import SwiftUI
import UsageCore

/// Borderless dark floating panel matching claude-usage-monitor (no native NSPopover arrow).
@MainActor
final class FloatingPanel: NSPanel {
    var onCloseRequested: (() -> Void)?

    init(contentViewController: NSViewController) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Metrics.popoverWidth, height: 480),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.contentViewController = contentViewController
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.level = .statusBar
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        self.isMovableByWindowBackground = false
        self.appearance = NSAppearance(named: .darkAqua)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCloseRequested?()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let preferences = AppPreferences()
    private lazy var store = UsageMonitorStore(preferences: preferences)
    private var statusItem: NSStatusItem!
    private var panel: FloatingPanel!
    private var hostingController: NSHostingController<PanelView>!
    private var settingsWindow: NSWindow?
    private var globalClickMonitor: Any?
    private var localKeyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(handleStatusClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        hostingController = NSHostingController(
            rootView: PanelView(
                store: store,
                preferences: preferences,
                onOpenSettings: { [weak self] in self?.openSettingsWindow() },
                onQuit: { NSApp.terminate(nil) }
            )
        )

        panel = FloatingPanel(contentViewController: hostingController)
        panel.onCloseRequested = { [weak self] in self?.closePanel() }

        store.onMenuBarUpdate = { [weak self] in
            self?.updateStatusButton()
        }
        updateStatusButton()
    }

    @objc private func handleStatusClick(_ sender: AnyObject?) {
        if let event = NSApp.currentEvent, event.type == .rightMouseUp {
            let l10n = preferences.l10n
            let menu = NSMenu()
            menu.addItem(withTitle: l10n.refresh, action: #selector(refreshAction), keyEquivalent: "r")
            menu.addItem(withTitle: l10n.settings, action: #selector(openSettingsAction), keyEquivalent: ",")
            menu.addItem(.separator())
            menu.addItem(withTitle: l10n.quit, action: #selector(quitAction), keyEquivalent: "q")
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
            return
        }

        if panel.isVisible {
            closePanel()
        } else {
            openPanel()
        }
    }

    private func openPanel() {
        store.refreshNow()
        positionPanelUnderStatusItem()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        installDismissMonitors()
    }

    private func closePanel() {
        panel.orderOut(nil)
        removeDismissMonitors()
    }

    private func positionPanelUnderStatusItem() {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))

        hostingController.view.layoutSubtreeIfNeeded()
        let fittingSize = hostingController.view.fittingSize
        let inset = Metrics.shadowInset
        let screenFrame = buttonWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let maxHeight = max(420, screenFrame.height - 24)
        let panelWidth = Metrics.popoverWidth + inset * 2
        let panelHeight = min(maxHeight, max(300, fittingSize.height))

        var x = buttonFrame.midX - panelWidth / 2.0
        x = max(screenFrame.minX + 4 - inset, min(x, screenFrame.maxX - panelWidth + inset - 4))
        let y = buttonFrame.minY - panelHeight + inset - 6

        panel.setFrame(NSRect(x: x, y: y, width: panelWidth, height: panelHeight), display: true)
    }

    private func installDismissMonitors() {
        removeDismissMonitors()
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                self?.closePanel()
            }
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if event.keyCode == 53 { // Esc
                Task { @MainActor in
                    self?.closePanel()
                }
                return nil
            }
            return event
        }
    }

    private func removeDismissMonitors() {
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
            globalClickMonitor = nil
        }
        if let monitor = localKeyMonitor {
            NSEvent.removeMonitor(monitor)
            localKeyMonitor = nil
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
        closePanel()
        if let existing = settingsWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(
            rootView: SettingsView(store: store, preferences: preferences)
        )
        let window = NSWindow(contentViewController: hosting)
        window.title = ""
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.center()
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func updateStatusButton() {
        guard let button = statusItem.button else { return }
        button.title = ""
        button.attributedTitle = NSAttributedString(string: "")
        button.imagePosition = .imageOnly
        button.image = MenuBarRenderer.render(columns: store.menuBarColumns())
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
