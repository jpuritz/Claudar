import AppKit
import SwiftUI
import Combine
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let model = UsageModel()
    private let status = StatusModel()
    private var usageWindow: UsageWindowController!
    private var timer: Timer?
    private var statusTimer: Timer?
    private var cancellable: AnyCancellable?
    private var statusCancellable: AnyCancellable?
    private let menu = NSMenu()
    private lazy var cookieSignIn = CookieSignInController(onSaved: { [weak self] in
        self?.model.cookieDidChange()
    })

    private static let windowVisibleKey = "ShowUsageWindow"

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageLeading
        menu.delegate = self
        statusItem.menu = menu
        updateStatusButton()

        NotificationManager.shared.setup()

        usageWindow = UsageWindowController(model: model)
        // Closing the window is a visibility change too — persist it so the
        // window doesn't reappear on next launch after being closed.
        usageWindow.onVisibilityChange = { [weak self] in
            guard let self else { return }
            UserDefaults.standard.set(self.usageWindow.isVisible, forKey: Self.windowVisibleKey)
        }
        // Default to closed now that the widget covers at-a-glance viewing.
        if UserDefaults.standard.object(forKey: Self.windowVisibleKey) as? Bool ?? false {
            usageWindow.show()
        }

        cancellable = model.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.updateStatusButton() }
            }
        statusCancellable = status.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.updateStatusButton() }
            }

        model.refresh()
        status.refresh()
        startPollTimer()
        // Claude's status changes far less often than usage; poll it every 3 min.
        statusTimer = Timer.scheduledTimer(withTimeInterval: 180, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.status.refresh() }
        }

        // Refresh promptly after the Mac wakes — the timer alone can leave the
        // first post-wake reading minutes stale.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Both read prompt-free now: status hits a public endpoint, and usage
            // reads the app's own cached token (not Claude Code's Keychain item).
            Task { @MainActor in
                self?.model.refresh(force: true)
                self?.status.refresh()
            }
        }

        if Prefs.hotkeyEnabled { enableHotkey(true) }
    }

    /// Handles `claudar://window`, which is what the desktop widget opens when
    /// clicked. Without this the widget is a dead end: the app is an accessory
    /// with no Dock icon, so activating it shows the user nothing.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard urls.contains(where: { $0.scheme == ClaudarURL.scheme }) else { return }
        usageWindow.show()
        UserDefaults.standard.set(true, forKey: Self.windowVisibleKey)
        model.refresh(force: true)
    }

    /// (Re)starts the usage poll timer at the user's chosen interval.
    private func startPollTimer() {
        timer?.invalidate()
        let interval = TimeInterval(Prefs.pollInterval)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.model.refresh() }
        }
    }

    private func enableHotkey(_ on: Bool) {
        HotkeyManager.shared.setEnabled(on) { [weak self] in
            guard let self else { return }
            self.usageWindow.show()
            UserDefaults.standard.set(true, forKey: Self.windowVisibleKey)
        }
    }

    // MARK: - Menu bar button

    private func updateStatusButton() {
        guard let button = statusItem.button else { return }
        // Overlay a small incident dot on the ring only when a service is down.
        let incident = !status.health.isOperational && status.health != .unknown
        let dotColor = incident ? status.health.nsColor : nil

        if let shown = model.menuBarUtilization {
            button.image = Self.ringImage(fraction: shown / 100.0, incidentDot: dotColor)
            button.attributedTitle = NSAttributedString(
                string: " \(UsageFormat.percent(shown))",
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)]
            )
            var tip = model.limits
                .map { "\($0.label): \(UsageFormat.percent($0.utilization))" }
                .joined(separator: "\n")
            if incident { tip += "\n⚠︎ Claude: \(status.summary)" }
            button.toolTip = tip
        } else {
            button.image = Self.ringImage(fraction: 0, incidentDot: dotColor)
            button.attributedTitle = NSAttributedString(
                string: " –",
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)]
            )
            button.toolTip = model.errorMessage
        }
    }

    /// Small progress ring, colored by severity, with an optional incident dot.
    private static func ringImage(fraction: Double, incidentDot: NSColor? = nil) -> NSImage {
        let side: CGFloat = 16
        let img = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let lineWidth: CGFloat = 2.5
            let r = rect.insetBy(dx: lineWidth / 2 + 0.5, dy: lineWidth / 2 + 0.5)
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let radius = r.width / 2

            let track = NSBezierPath()
            track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            track.lineWidth = lineWidth
            NSColor.secondaryLabelColor.withAlphaComponent(0.35).setStroke()
            track.stroke()

            if fraction > 0.005 {
                let color = Severity.forPercent(fraction * 100).nsColor
                let arc = NSBezierPath()
                // Start at 12 o'clock, sweep clockwise.
                arc.appendArc(
                    withCenter: center, radius: radius,
                    startAngle: 90, endAngle: 90 - 360 * min(fraction, 1.0),
                    clockwise: true
                )
                arc.lineWidth = lineWidth
                arc.lineCapStyle = .round
                color.setStroke()
                arc.stroke()
            }

            if let incidentDot {
                let d: CGFloat = 6
                let dotRect = NSRect(x: rect.maxX - d, y: rect.maxY - d, width: d, height: d)
                incidentDot.setFill()
                NSBezierPath(ovalIn: dotRect).fill()
            }
            return true
        }
        img.isTemplate = false
        return img
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        // Note: no refresh here — a Keychain prompt triggered while the menu is
        // open can't receive keyboard input (menu tracking captures key events).
        menu.removeAllItems()

        let panelItem = NSMenuItem()
        let hosting = NSHostingView(rootView: UsagePanelView(model: model))
        let size = hosting.fittingSize
        hosting.frame = NSRect(x: 0, y: 0, width: max(264, size.width), height: size.height)
        panelItem.view = hosting
        menu.addItem(panelItem)

        // Organization switcher. Only drawn when the login actually has more than
        // one org, so the common single-org menu is unchanged.
        if model.orgs.count > 1 {
            menu.addItem(.separator())
            let header = NSMenuItem(title: "Organization", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)

            let showAll = NSMenuItem(
                title: "Show All at Once",
                action: #selector(toggleShowAllOrgs), keyEquivalent: ""
            )
            showAll.target = self
            showAll.state = model.showAllOrgs ? .on : .off
            showAll.toolTip = "List every org's limits together instead of only the active one."
            menu.addItem(showAll)

            let activeID = model.activeOrg?.id
            for org in model.orgs {
                let pct = model.sessionPercent(for: org.id)
                let item = NSMenuItem(
                    title: pct.map { "\(org.name) · \(UsageFormat.percent($0))" } ?? org.name,
                    action: #selector(selectOrg(_:)), keyEquivalent: ""
                )
                item.target = self
                item.representedObject = org.id
                item.state = (org.id == activeID) ? .on : .off
                let plan = org.plan.map { " · \($0)" } ?? ""
                item.toolTip = model.showAllOrgs
                    ? "\(org.name)\(plan). Checked means the menu bar ring follows this org."
                    : "\(org.name)\(plan)"
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        // Claude service health — a single summary line, colored.
        let statusItemLine = NSMenuItem()
        statusItemLine.attributedTitle = statusMenuTitle()
        statusItemLine.action = #selector(openStatusPage)
        statusItemLine.target = self
        statusItemLine.toolTip = status.components
            .map { "\($0.name): \(status.statusLabel($0.status))" }
            .joined(separator: "\n")
        menu.addItem(statusItemLine)

        menu.addItem(.separator())

        let refresh = NSMenuItem(title: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        let widgetToggle = NSMenuItem(
            title: "Usage Window",
            action: #selector(toggleWindow), keyEquivalent: "w"
        )
        widgetToggle.target = self
        widgetToggle.state = usageWindow.isVisible ? .on : .off
        menu.addItem(widgetToggle)

        let floatItem = NSMenuItem(
            title: "Keep Window on Top",
            action: #selector(toggleFloat), keyEquivalent: ""
        )
        floatItem.target = self
        floatItem.state = UsageWindowController.floats ? .on : .off
        menu.addItem(floatItem)

        let notifMenu = NSMenu()
        let notifItem = NSMenuItem(title: "Notifications", action: nil, keyEquivalent: "")
        notifItem.submenu = notifMenu
        for (title, key) in [
            ("Alert at 80% and 95%", "thresholds"),
            ("Alert When Limits Reset", "resets"),
            ("Usage Pace Warnings", "pace"),
            ("Claude Service Alerts", "status"),
        ] {
            let item = NSMenuItem(title: title, action: #selector(toggleNotifPref(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = key
            item.state = Self.notifPref(key) ? .on : .off
            notifMenu.addItem(item)
        }
        menu.addItem(notifItem)

        // Refresh interval submenu.
        let intervalMenu = NSMenu()
        let intervalItem = NSMenuItem(title: "Refresh Interval", action: nil, keyEquivalent: "")
        intervalItem.submenu = intervalMenu
        for secs in Prefs.pollChoices {
            let item = NSMenuItem(
                title: secs < 60 ? "\(secs) seconds" : "\(secs / 60) minute\(secs == 60 ? "" : "s")",
                action: #selector(setInterval(_:)), keyEquivalent: ""
            )
            item.target = self
            item.tag = secs
            item.state = Prefs.pollInterval == secs ? .on : .off
            intervalMenu.addItem(item)
        }
        menu.addItem(intervalItem)

        let hotkeyItem = NSMenuItem(
            title: "Global Shortcut (\(HotkeyManager.comboDescription))",
            action: #selector(toggleHotkey), keyEquivalent: ""
        )
        hotkeyItem.target = self
        hotkeyItem.state = Prefs.hotkeyEnabled ? .on : .off
        hotkeyItem.toolTip = "Open the usage window from anywhere with \(HotkeyManager.comboDescription)."
        menu.addItem(hotkeyItem)

        // No-Prompt Mode — sign in to claude.ai so usage reads never prompt.
        let npMenu = NSMenu()
        let npItem = NSMenuItem(title: "No-Prompt Mode", action: nil, keyEquivalent: "")
        npItem.submenu = npMenu
        if KeychainReader.readCookie() != nil {
            let on = NSMenuItem(title: "On — signed in to claude.ai", action: nil, keyEquivalent: "")
            on.state = .on
            npMenu.addItem(on)
            let re = NSMenuItem(title: "Re-sign In…", action: #selector(signInCookie), keyEquivalent: "")
            re.target = self
            npMenu.addItem(re)
            let off = NSMenuItem(title: "Turn Off (use CLI sign-in)", action: #selector(turnOffCookie), keyEquivalent: "")
            off.target = self
            npMenu.addItem(off)
        } else {
            let on = NSMenuItem(title: "Sign In to claude.ai…", action: #selector(signInCookie), keyEquivalent: "")
            on.target = self
            npMenu.addItem(on)
            let hint = NSMenuItem(title: "Stops the periodic password prompt", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            npMenu.addItem(hint)
        }
        menu.addItem(npItem)

        let login = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLogin), keyEquivalent: ""
        )
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Claudar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    func menuDidClose(_ menu: NSMenu) {
        // Refresh after the menu closes so any Keychain prompt is typeable.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.model.refreshIfStale(seconds: 30)
        }
    }

    /// The colored "Claude services: …" line shown in the menu.
    private func statusMenuTitle() -> NSAttributedString {
        let dot = "●  "
        let text: String
        let color: NSColor
        switch status.health {
        case .none:
            text = "All Claude services operational"; color = ServiceHealth.none.nsColor
        case .unknown:
            text = "Claude status: checking…"; color = .secondaryLabelColor
        default:
            // Name the affected services when we have them.
            let down = status.components.filter { !$0.isOperational }.map(\.name)
            text = down.isEmpty
                ? "Claude: \(status.summary)"
                : "Claude issue: \(down.joined(separator: ", "))"
            color = status.health.nsColor
        }
        let s = NSMutableAttributedString(
            string: dot, attributes: [.foregroundColor: color, .font: NSFont.systemFont(ofSize: 11)]
        )
        s.append(NSAttributedString(
            string: text,
            attributes: [.foregroundColor: NSColor.labelColor, .font: NSFont.systemFont(ofSize: 12)]
        ))
        return s
    }

    @objc private func toggleShowAllOrgs() {
        model.showAllOrgs.toggle()
        // The panel's height changes a lot here, so let the window re-fit.
        usageWindow.refit()
    }

    @objc private func selectOrg(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        model.selectOrg(id)
    }

    @objc private func openStatusPage() {
        NSWorkspace.shared.open(URL(string: "https://status.claude.com")!)
    }

    @objc private func setInterval(_ sender: NSMenuItem) {
        Prefs.pollInterval = sender.tag
        startPollTimer()
        model.refresh(force: true)
    }

    @objc private func toggleHotkey() {
        Prefs.hotkeyEnabled.toggle()
        enableHotkey(Prefs.hotkeyEnabled)
    }

    @objc private func signInCookie() {
        cookieSignIn.present()
    }

    @objc private func turnOffCookie() {
        KeychainReader.clearCookie()
        model.cookieDidChange()
    }

    private static func notifPref(_ key: String) -> Bool {
        switch key {
        case "thresholds": return Prefs.notifyThresholds
        case "resets": return Prefs.notifyResets
        case "status": return Prefs.notifyStatus
        default: return Prefs.notifyPace
        }
    }

    @objc private func toggleNotifPref(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        switch key {
        case "thresholds": Prefs.notifyThresholds.toggle()
        case "resets":
            Prefs.notifyResets.toggle()
            // Cancel across every org, not just the one on screen.
            if !Prefs.notifyResets { AlertEngine.shared.cancelAllResetSchedules() }
        case "status": Prefs.notifyStatus.toggle()
        default: Prefs.notifyPace.toggle()
        }
    }

    @objc private func refreshNow() {
        model.refresh(force: true)
    }

    @objc private func toggleWindow() {
        usageWindow.toggle()
        UserDefaults.standard.set(usageWindow.isVisible, forKey: Self.windowVisibleKey)
    }

    @objc private func toggleFloat() {
        UsageWindowController.floats.toggle()
        usageWindow.applyFloating(UsageWindowController.floats)
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn’t change Launch at Login"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}
