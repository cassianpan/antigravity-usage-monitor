import AppKit
import QuartzCore
import SwiftUI
import UsageCore

/// Borderless dark floating panel matching claude-usage-monitor (no native NSPopover arrow).
@MainActor
final class FloatingPanel: NSPanel {
    var onCloseRequested: (() -> Void)?
    /// Top screen Y coordinate to keep pinned whenever content height changes.
    var anchoredTopY: CGFloat?

    init(contentViewController: NSViewController) {
        let initialWidth = Metrics.popoverWidth + Metrics.shadowInset * 2
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: initialWidth, height: 480),
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

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        // Allow transparent shadowInset padding to overlap the menu bar area so topY stays exact.
        frameRect
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        var adjusted = frameRect
        if let topY = anchoredTopY {
            adjusted.origin.y = topY - adjusted.size.height
        }
        super.setFrame(adjusted, display: flag)
    }

    override func setFrame(_ frameRect: NSRect, display displayFlag: Bool, animate animateFlag: Bool) {
        var adjusted = frameRect
        if let topY = anchoredTopY {
            adjusted.origin.y = topY - adjusted.size.height
        }
        super.setFrame(adjusted, display: displayFlag, animate: animateFlag)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCloseRequested?()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private struct DisclosureTrack {
        var startValue: Double
        var targetValue: Double
        var startTime: CFTimeInterval
        var duration: CFTimeInterval
    }

    private let preferences = AppPreferences()
    private let tipCenter = TipCenter()
    private let interaction = PanelInteractionState()
    private lazy var store = UsageMonitorStore(preferences: preferences)
    private var statusItem: NSStatusItem!
    private var panel: FloatingPanel!
    private var hostingController: NSHostingController<PanelView>!
    private var settingsWindow: NSWindow?
    private var globalClickMonitor: Any?
    private var localKeyMonitor: Any?
    private var menuBarAnimTimer: Timer?
    private var menuBarSpinning: Bool = false
    private var menuBarSpinAngle: CGFloat = 0
    private var menuBarBreathPhase: CGFloat = .pi
    private var disclosureTracks: [String: DisclosureTrack] = [:]
    private var disclosureDisplayLink: CADisplayLink?
    private var liveRefreshTimer: Timer?
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installTerminationSignalHandlers()
        DispatchQueue.global(qos: .utility).async {
            SilentCLISyncer.sweepOrphanedProbes()
        }
        if preferences.enableUsageAlerts || preferences.enableBillingReminders {
            NotificationManager.shared.requestPermissionIfNeeded()
        }

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
                tipCenter: tipCenter,
                interaction: interaction,
                onOpenSettings: { [weak self] in self?.openSettingsWindow() },
                onRefresh: { [weak self] in self?.triggerRefreshWithSpin() },
                onQuit: { NSApp.terminate(nil) },
                onToggleDisclosure: { [weak self] key, expanded in
                    self?.toggleDisclosure(key: key, expanded: expanded)
                },
                onPreferredHeightChange: { [weak self] height in
                    self?.handlePreferredHeightChange(height)
                }
            )
        )
        hostingController.sizingOptions = []

        panel = FloatingPanel(contentViewController: hostingController)
        panel.onCloseRequested = { [weak self] in self?.closePanel() }

        store.onMenuBarUpdate = { [weak self] in
            self?.updateStatusButton()
        }
        store.onSyncStateChanged = { [weak self] syncing in
            self?.setMenuBarSpinning(syncing)
        }
        updateStatusButton()
        if store.isSyncingOfficial {
            setMenuBarSpinning(true)
        }
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
        interaction.resetHovers()
        tipCenter.setActive(true)
        store.refreshNow()
        positionPanelUnderStatusItem()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        installDismissMonitors()
        interaction.triggerRefreshSpin()
        liveRefreshTimer?.invalidate()
        liveRefreshTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.panel.isVisible else { return }
                self.store.refreshNow()
            }
        }
        Task { [weak self] in
            await self?.store.syncOfficialInBackground(force: false)
            await self?.store.checkForUpdatesIfNeeded()
        }
    }

    private func closePanel() {
        liveRefreshTimer?.invalidate()
        liveRefreshTimer = nil
        finishAllDisclosureAnimations()
        tipCenter.setActive(false)
        interaction.resetHovers()
        panel.orderOut(nil)
        removeDismissMonitors()
    }

    private func triggerRefreshWithSpin() {
        interaction.triggerRefreshSpin()
        store.refreshNow()
        Task { [weak self] in
            await self?.store.syncOfficialInBackground(force: true, userInitiated: true)
        }
    }

    private func positionPanelUnderStatusItem() {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))

        let inset = Metrics.shadowInset
        let panelWidth = Metrics.popoverWidth + inset * 2
        let screenFrame = buttonWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let maxHeight = max(420, screenFrame.height - 24)
        let fittingSize = hostingController.sizeThatFits(
            in: CGSize(width: panelWidth, height: .greatestFiniteMagnitude)
        )
        let panelHeight = min(maxHeight, max(120, ceil(fittingSize.height)))

        var x = buttonFrame.midX - panelWidth / 2.0
        x = max(screenFrame.minX + 4 - inset, min(x, screenFrame.maxX - panelWidth + inset - 4))
        let topY = buttonFrame.minY + inset - 6
        let y = topY - panelHeight

        panel.anchoredTopY = topY
        panel.setFrame(NSRect(x: x, y: y, width: panelWidth, height: panelHeight), display: true)
        hostingController.view.layoutSubtreeIfNeeded()
    }

    private func clampedPanelHeight(for preferredHeight: CGFloat) -> CGFloat {
        let screenFrame = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let maxHeight = max(420, screenFrame.height - 24)
        return min(maxHeight, max(120, ceil(preferredHeight)))
    }

    private func applyPanelHeight(_ preferredHeight: CGFloat) {
        guard preferredHeight > 0 else { return }
        let targetHeight = clampedPanelHeight(for: preferredHeight)
        let current = panel.frame
        guard abs(current.height - targetHeight) > 0.5 else { return }
        let topY = panel.anchoredTopY ?? current.maxY
        panel.setFrame(
            NSRect(x: current.origin.x, y: topY - targetHeight, width: current.width, height: targetHeight),
            display: false,
            animate: false
        )
    }

    private func handlePreferredHeightChange(_ newHeight: CGFloat) {
        guard panel.isVisible, disclosureTracks.isEmpty, newHeight > 0 else { return }
        let targetHeight = clampedPanelHeight(for: newHeight)
        guard abs(panel.frame.height - targetHeight) > 0.5 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        applyPanelHeight(newHeight)
        hostingController.view.layoutSubtreeIfNeeded()
    }

    private func toggleDisclosure(key: String, expanded: Bool) {
        let target = expanded ? 1.0 : 0.0
        if !panel.isVisible || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            disclosureTracks.removeValue(forKey: key)
            interaction.disclosureProgress[key] = target
            if panel.isVisible {
                syncPanelHeightNow()
            }
            return
        }

        let current = interaction.disclosureProgress[key] ?? (expanded ? 0.0 : 1.0)
        let distance = abs(target - current)
        guard distance > 0.001 else {
            interaction.disclosureProgress[key] = target
            return
        }

        disclosureTracks[key] = DisclosureTrack(
            startValue: current,
            targetValue: target,
            startTime: CACurrentMediaTime(),
            duration: max(0.05, 0.18 * distance)
        )
        interaction.disclosureProgress[key] = current

        if disclosureDisplayLink == nil {
            let link = panel.displayLink(target: self, selector: #selector(stepDisclosureAnimation(_:)))
            link.add(to: .main, forMode: .common)
            disclosureDisplayLink = link
        }
    }

    @objc private func stepDisclosureAnimation(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        var completedKeys: [String] = []

        for (key, track) in disclosureTracks {
            let t = min(1.0, max(0.0, (now - track.startTime) / track.duration))
            let eased = 1.0 - pow(1.0 - t, 3.0)
            let value = track.startValue + (track.targetValue - track.startValue) * eased
            interaction.disclosureProgress[key] = value
            if t >= 1.0 {
                interaction.disclosureProgress[key] = track.targetValue
                completedKeys.append(key)
            }
        }

        for key in completedKeys {
            disclosureTracks.removeValue(forKey: key)
        }

        if disclosureTracks.isEmpty {
            disclosureDisplayLink?.invalidate()
            disclosureDisplayLink = nil
        }

        syncPanelHeightNow()
    }

    private func syncPanelHeightNow() {
        let panelWidth = Metrics.popoverWidth + Metrics.shadowInset * 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let fittingSize = hostingController.sizeThatFits(
            in: CGSize(width: panelWidth, height: .greatestFiniteMagnitude)
        )
        applyPanelHeight(fittingSize.height)
        hostingController.view.layoutSubtreeIfNeeded()
    }

    private func finishAllDisclosureAnimations() {
        disclosureDisplayLink?.invalidate()
        disclosureDisplayLink = nil
        for (key, track) in disclosureTracks {
            interaction.disclosureProgress[key] = track.targetValue
        }
        disclosureTracks.removeAll()
    }

    private func installDismissMonitors() {
        removeDismissMonitors()
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                self?.closePanel()
            }
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.panel.isVisible else { return event }
            if event.keyCode == 53 { // Esc
                Task { @MainActor in self.closePanel() }
                return nil
            }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags == .command, let chars = event.charactersIgnoringModifiers?.lowercased() {
                switch chars {
                case ",":
                    Task { @MainActor in self.openSettingsWindow() }
                    return nil
                case "r":
                    Task { @MainActor in self.triggerRefreshWithSpin() }
                    return nil
                case "q":
                    Task { @MainActor in NSApp.terminate(nil) }
                    return nil
                default:
                    break
                }
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

    private func setMenuBarSpinning(_ spinning: Bool) {
        menuBarSpinning = spinning
        if !spinning {
            menuBarSpinAngle = 0
        }
        syncMenuBarAnimationTimer()
        updateStatusButton()
    }

    private func activeMenuBarAgentCount() -> Int {
        preferences.showRunningAgentsInMenuBar ? store.runningAgents.totalCount : 0
    }

    private func syncMenuBarAnimationTimer() {
        let shouldBreathe = activeMenuBarAgentCount() > 0 && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let needsTimer = menuBarSpinning || shouldBreathe

        if needsTimer {
            guard menuBarAnimTimer == nil else { return }
            menuBarAnimTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    if self.menuBarSpinning {
                        self.menuBarSpinAngle += (.pi * 2.0) / 28.0
                        if self.menuBarSpinAngle >= .pi * 2.0 {
                            self.menuBarSpinAngle -= .pi * 2.0
                        }
                    }
                    if self.activeMenuBarAgentCount() > 0 && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                        self.menuBarBreathPhase += (.pi * 2.0) / 40.0
                        if self.menuBarBreathPhase >= .pi * 2.0 {
                            self.menuBarBreathPhase -= .pi * 2.0
                        }
                    } else {
                        self.menuBarBreathPhase = .pi
                    }
                    self.updateStatusButton()
                }
            }
        } else {
            menuBarAnimTimer?.invalidate()
            menuBarAnimTimer = nil
            menuBarSpinAngle = 0
            menuBarBreathPhase = .pi
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        menuBarAnimTimer?.invalidate()
        menuBarAnimTimer = nil
        store.flushPendingState()
        ActiveSyncProcessRegistry.shared.terminateAllImmediately()
    }

    private func installTerminationSignalHandlers() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                self?.store.flushPendingState()
                ActiveSyncProcessRegistry.shared.terminateAllImmediately()
                NSApp.terminate(nil)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private func updateStatusButton() {
        syncMenuBarAnimationTimer()
        guard let button = statusItem.button else { return }
        let agentCount = activeMenuBarAgentCount()
        let phase: CGFloat = (agentCount > 0 && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
            ? menuBarBreathPhase
            : .pi
        button.title = ""
        button.attributedTitle = NSAttributedString(string: "")
        button.imagePosition = .imageOnly
        button.image = MenuBarRenderer.render(
            columns: store.menuBarColumns(),
            spinAngleRadians: menuBarSpinAngle,
            runningAgentCount: agentCount,
            breathingPhase: phase
        )
    }
}

@main
struct AntigravityUsageMonitorApp {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if let first = args.first {
            if first == AgySyncWrapper.flag {
                Darwin.exit(AgySyncWrapper.run(arguments: Array(args.dropFirst())))
            }
            if first == CLILoginSupervisor.flag {
                Darwin.exit(CLILoginSupervisor.run(arguments: Array(args.dropFirst())))
            }
        }

        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let delegate = AppDelegate()
            app.delegate = delegate
            app.run()
        }
    }
}
