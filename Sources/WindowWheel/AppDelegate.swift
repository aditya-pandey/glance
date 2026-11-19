import AppKit
import ServiceManagement

public final class AppDelegate: NSObject, NSApplicationDelegate, HotkeyManagerDelegate {
    private var statusItem: NSStatusItem?
    private var hotkeyManager: HotkeyManager?
    private var dockMenuToggle: NSMenuItem?
    private var launchAtLoginToggle: NSMenuItem?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // 1. Setup Overlay Controller Callbacks
        OverlayPanelController.shared.onCommitCallback = { [weak self] in
            self?.hotkeyManager?.endSession()
        }
        OverlayPanelController.shared.onEnterStickySearch = { [weak self] in
            self?.hotkeyManager?.beginStickySession()
        }

        // 2. Register Hotkeys (Option + Tab = Grid, Option + ~ = Current App, Option + Shift + Tab = Reverse)
        let hotkey = HotkeyManager()
        hotkey.delegate = self
        hotkey.registerHotkeys()
        self.hotkeyManager = hotkey

        // 3. Setup Windows-style Dock Hover Previews
        DockHoverMonitor.shared.isMouseOverStrip = {
            OverlayPanelController.shared.isMouseInsideDockStrip()
        }
        DockHoverMonitor.shared.isStripVisible = {
            OverlayPanelController.shared.isDockPreviewVisible()
        }
        DockHoverMonitor.shared.onHoverApp = { app, iconRect in
            OverlayPanelController.shared.presentDockPreview(for: app, iconRectAppKit: iconRect)
        }
        DockHoverMonitor.shared.onDismissStrip = {
            OverlayPanelController.shared.dismissDockPreview()
        }
        DockHoverMonitor.shared.start()

        // 4. Setup Menu Bar Item
        setupStatusBar()

        // 5. Warm initial window cache off main thread (only pre-warm thumbnails when Screen Recording is already allowed)
        WindowEnumerator.shared.refreshWindowsAsync { initialWins in
            if CGPreflightScreenCaptureAccess() {
                WindowEnumerator.shared.captureThumbnailsAsync(for: initialWins, maxThumbWidth: 260)
            }
        }

        if !AXIsProcessTrusted() && !UserDefaults.standard.bool(forKey: "GlanceShownPermissionsOnce") {
            UserDefaults.standard.set(true, forKey: "GlanceShownPermissionsOnce")
            PermissionsWindowController.shared.show()
        }

        print("[Glance] Ready: ⌥Tab = Visual Grid | ⌥~ = Same-App Windows | Dock Hover Previews Active")
    }

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            if let customURL = Bundle.main.url(forResource: "MenuBarTemplate", withExtension: "png"),
               let customImg = NSImage(contentsOf: customURL) {
                customImg.size = NSSize(width: 18, height: 18)
                customImg.isTemplate = true
                button.image = customImg
            } else {
                button.image = NSImage(systemSymbolName: "macwindow.on.rectangle", accessibilityDescription: "Glance")
            }
        }

        let menu = NSMenu()
        let header = NSMenuItem(title: "Glance (⌥ Tab · ⌥ ~)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(NSMenuItem.separator())

        menu.addItem(NSMenuItem(title: "Switch Windows & Tabs (Sticky Search)", action: #selector(openStickyGrid), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Current App Windows Only", action: #selector(openSameAppSticky), keyEquivalent: ""))

        let dockToggle = NSMenuItem(title: "Dock Hover Window Previews", action: #selector(toggleDockHover), keyEquivalent: "")
        dockToggle.state = DockHoverMonitor.shared.isEnabled ? .on : .off
        self.dockMenuToggle = dockToggle
        menu.addItem(dockToggle)

        let loginToggle = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginToggle.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        self.launchAtLoginToggle = loginToggle
        menu.addItem(loginToggle)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Permissions…", action: #selector(openPermissionsWindow), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Relaunch Glance (Apply Permissions)", action: #selector(relaunchSelf), keyEquivalent: "r"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Glance", action: #selector(quitApp), keyEquivalent: "q"))

        statusItem?.menu = menu
    }

    @objc private func openStickyGrid() {
        hotkeyManager?.beginStickySession()
        OverlayPanelController.shared.presentMainGrid(sameAppOnly: false, reverse: false, sticky: true)
    }

    @objc private func openSameAppSticky() {
        hotkeyManager?.beginStickySession()
        OverlayPanelController.shared.presentMainGrid(sameAppOnly: true, reverse: false, sticky: true)
    }

    @objc private func toggleDockHover() {
        DockHoverMonitor.shared.isEnabled.toggle()
        dockMenuToggle?.state = DockHoverMonitor.shared.isEnabled ? .on : .off
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            print("[Glance] Launch at login update error: \(error)")
        }
        launchAtLoginToggle?.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
    }

    @objc private func openPermissionsWindow() {
        PermissionsWindowController.shared.show()
    }

    @objc private func relaunchSelf() {
        WindowEnumerator.shared.relaunchApplication()
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - HotkeyManagerDelegate
    public func switcherTriggered(sameAppOnly: Bool, reverse: Bool) {
        OverlayPanelController.shared.dismissDockPreview()
        OverlayPanelController.shared.presentMainGrid(sameAppOnly: sameAppOnly, reverse: reverse, sticky: false)
    }

    public func switcherStep(delta: Int) {
        OverlayPanelController.shared.stepSelection(delta: delta)
    }

    public func switcherArrows(keyCode: UInt16) {
        OverlayPanelController.shared.moveSelectionArrow(keyCode: keyCode)
    }

    public func switcherLockSticky(initialChar: String?) {
        OverlayPanelController.shared.transitionToStickySearch(initialChar: initialChar)
    }

    public func switcherCloseSelected() {
        OverlayPanelController.shared.closeSelectedWindow()
    }

    public func switcherCommitAndHide() {
        OverlayPanelController.shared.commitSelectionAndHide()
    }

    public func switcherCancel() {
        OverlayPanelController.shared.cancelAndHide()
    }
}
