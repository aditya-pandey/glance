import AppKit
import SwiftUI

public final class SwitcherPanel: NSPanel {
    public var onEscape: (() -> Void)?
    public var onCommandW: (() -> Void)?
    public weak var searchField: NSTextField?
    public var isStickySearchActive: Bool = false

    override public var canBecomeKey: Bool { true }
    override public var canBecomeMain: Bool { true }

    public func focusSearchField() {
        guard let tf = searchField else { return }
        self.makeFirstResponder(tf)
        if let editor = tf.currentEditor() {
            editor.selectedRange = NSRange(location: tf.stringValue.count, length: 0)
        }
    }

    override public func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    override public func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            if event.keyCode == 53 {
                onEscape?()
                return
            }
            if isStickySearchActive,
               let tf = searchField,
               self.firstResponder !== tf && self.firstResponder !== tf.currentEditor(),
               !event.modifierFlags.contains(.command),
               !event.modifierFlags.contains(.control) {
                self.makeFirstResponder(tf)
            }
            if isStickySearchActive,
               event.modifierFlags.contains(.option),
               !event.modifierFlags.contains(.command),
               !event.modifierFlags.contains(.control),
               let clean = event.charactersIgnoringModifiers,
               let first = clean.first,
               (first.isLetter || first.isNumber || first == " ") {
                let cleanFlags = event.modifierFlags.subtracting(.option)
                if let cleanEvent = NSEvent.keyEvent(
                    with: .keyDown,
                    location: event.locationInWindow,
                    modifierFlags: cleanFlags,
                    timestamp: event.timestamp,
                    windowNumber: event.windowNumber,
                    context: nil,
                    characters: clean,
                    charactersIgnoringModifiers: clean,
                    isARepeat: event.isARepeat,
                    keyCode: event.keyCode
                ) {
                    super.sendEvent(cleanEvent)
                    return
                }
            }
        }
        super.sendEvent(event)
    }
}

public final class SwitcherState: ObservableObject {
    @Published public var scope: SwitcherScope = .allWindows
    @Published public var searchQuery: String = ""
    @Published public var selectedWindowIndex: Int = 0
    @Published public var selectedTabIndex: Int = 0
    @Published public var isStickyMode: Bool = false
    @Published public var isPresented: Bool = false
    @Published public var frontAppName: String = ""
    @Published public var expandedBrowserBundleID: String? = nil

    public weak var searchTextField: NSTextField?
}

public final class DockStripState: ObservableObject {
    @Published public var appName: String = ""
    @Published public var appIcon: NSImage? = nil
    @Published public var windows: [WindowCardItem] = []
    @Published public var isPresented: Bool = false
}

public final class OverlayPanelController {
    public static let shared = OverlayPanelController()

    public let state = SwitcherState()
    public let dockState = DockStripState()

    private var mainPanel: SwitcherPanel?
    private var dockPanel: NSPanel?
    private var resignKeyObserver: NSObjectProtocol?
    private var previousApp: NSRunningApplication?
    private var mainPanelGeneration: Int = 0
    private var dockPanelGeneration: Int = 0
    private var showDelayWorkItem: DispatchWorkItem?
    private var isPendingShow: Bool = false
    private var openMouseLocation: CGPoint = .zero
    private let gridColumns = 4

    public var onCommitCallback: (() -> Void)?
    public var onEnterStickySearch: (() -> Void)?

    private init() {}

    public func hasMouseMovedSinceOpen() -> Bool {
        let cur = NSEvent.mouseLocation
        return hypot(cur.x - openMouseLocation.x, cur.y - openMouseLocation.y) > 4.0
    }

    // ─────────────────────────────────────────────────────────────
    // MARK: - Main Visual Window & Tab Switcher Grid
    // ─────────────────────────────────────────────────────────────

    public func presentMainGrid(sameAppOnly: Bool, reverse: Bool, sticky: Bool = false) {
        let front = NSWorkspace.shared.frontmostApplication
        if let front = front, front.bundleIdentifier != Bundle.main.bundleIdentifier {
            self.previousApp = front
            state.frontAppName = front.localizedName ?? "Current App"
        }

        mainPanelGeneration &+= 1
        let sessionGen = mainPanelGeneration
        showDelayWorkItem?.cancel()
        showDelayWorkItem = nil

        state.searchQuery = ""
        state.expandedBrowserBundleID = nil
        state.isStickyMode = sticky
        state.scope = sameAppOnly ? .currentApp : .allWindows

        // Seed selection immediately if we already have cached windows, and refresh off main thread without blocking UI!
        let cached = filteredWindows()
        state.selectedWindowIndex = cached.count >= 2 ? (reverse ? cached.count - 1 : 1) : 0
        state.selectedTabIndex = 0

        WindowEnumerator.shared.refreshWindowsAsync(prioritizingApp: previousApp) { [weak self] all in
            guard let self = self, self.mainPanelGeneration == sessionGen else { return }
            if CGPreflightScreenCaptureAccess() || WindowEnumerator.shared.hasScreenRecordingPermission {
                WindowEnumerator.shared.captureThumbnailsAsync(for: all, maxThumbWidth: 260)
            }
            let updatedVisible = self.filteredWindows()
            if self.state.selectedWindowIndex >= updatedVisible.count {
                self.state.selectedWindowIndex = updatedVisible.count >= 2 ? 1 : max(0, updatedVisible.count - 1)
            } else if cached.isEmpty && updatedVisible.count >= 2 {
                self.state.selectedWindowIndex = reverse ? updatedVisible.count - 1 : 1
            }
        }

        if sticky {
            isPendingShow = false
            showMainPanelNow(sticky: true)
        } else {
            // 150 ms quick-tap grace delay: fast Option+Tab taps switch immediately with zero HUD flash
            isPendingShow = true
            let work = DispatchWorkItem { [weak self] in
                guard let self = self, self.mainPanelGeneration == sessionGen, self.isPendingShow else { return }
                self.isPendingShow = false
                self.showMainPanelNow(sticky: false)
            }
            showDelayWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        }
    }

    private func showMainPanelNow(sticky: Bool) {
        ensureMainPanel()
        guard let panel = mainPanel else { return }
        panel.isStickySearchActive = sticky
        openMouseLocation = NSEvent.mouseLocation

        let screen = NSScreen.screens.first(where: { NSPointInRect(openMouseLocation, $0.frame) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let panelW = min(1008.0, visible.width - 32.0)
        let panelH = min(668.0, visible.height - 32.0)
        panel.setContentSize(NSSize(width: panelW, height: panelH))

        let origin = CGPoint(
            x: round(visible.midX - panelW / 2.0),
            y: round(visible.midY - panelH / 2.0)
        )
        panel.setFrameOrigin(origin)
        panel.searchField = state.searchTextField

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let alreadyVisible = panel.isVisible && state.isPresented
        if !alreadyVisible {
            panel.alphaValue = reduceMotion ? 1.0 : 0.0
            state.isPresented = reduceMotion
        }

        if sticky {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            panel.focusSearchField()
        } else {
            panel.orderFrontRegardless()
        }

        if reduceMotion {
            panel.alphaValue = 1.0
            state.isPresented = true
        } else {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.14
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1.0
            }
            withAnimation(.spring(response: 0.22, dampingFraction: 0.86)) {
                state.isPresented = true
            }
        }
    }

    public func filteredWindows() -> [WindowCardItem] {
        let all = WindowEnumerator.shared.windows
        let base: [WindowCardItem]
        switch state.scope {
        case .allWindows:
            base = all
        case .currentApp:
            base = all.filter { $0.isCurrentApp }
        case .browserTabs:
            base = []
        }

        let trimmed = state.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return base }
        let tokens = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return base.filter { item in
            let hay = "\(item.appName) \(item.title)".lowercased()
            return tokens.allSatisfy { hay.contains($0) }
        }
    }

    public func filteredTabs() -> [BrowserTabItem] {
        let allTabs = BrowserTabBridge.shared.tabs
        let trimmed = state.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if state.scope == .browserTabs {
            guard !trimmed.isEmpty else { return allTabs }
            let tokens = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            return allTabs.filter { tab in
                let hay = "\(tab.browserName) \(tab.title) \(tab.domain) \(tab.windowTitle)".lowercased()
                return tokens.allSatisfy { hay.contains($0) }
            }
        }

        // In All/CurrentApp scope, show matching browser tabs whenever searching or explicitly expanded!
        if !trimmed.isEmpty {
            let tokens = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            return Array(allTabs.filter { tab in
                let hay = "\(tab.browserName) \(tab.title) \(tab.domain) \(tab.windowTitle)".lowercased()
                return tokens.allSatisfy { hay.contains($0) }
            }.prefix(16))
        }

        if let expandedBundle = state.expandedBrowserBundleID {
            return allTabs.filter { $0.bundleID == expandedBundle }
        }

        return []
    }

    public func stepSelection(delta: Int) {
        let wins = filteredWindows()
        let tabs = filteredTabs()
        if state.scope == .browserTabs {
            guard !tabs.isEmpty else { return }
            state.selectedTabIndex = (state.selectedTabIndex + delta + tabs.count) % tabs.count
        } else {
            guard !wins.isEmpty else { return }
            state.selectedWindowIndex = (state.selectedWindowIndex + delta + wins.count) % wins.count
        }
    }

    public func moveSelectionArrow(keyCode: UInt16) {
        let wins = filteredWindows()
        guard !wins.isEmpty else { return }
        let cols = min(gridColumns, max(1, wins.count))
        var idx = state.selectedWindowIndex
        switch keyCode {
        case 123: idx = max(0, idx - 1)                // Left
        case 124: idx = min(wins.count - 1, idx + 1)   // Right
        case 126: idx = max(0, idx - cols)             // Up
        case 125: idx = min(wins.count - 1, idx + cols)// Down
        default: break
        }
        state.selectedWindowIndex = idx
    }

    public func transitionToStickySearch(initialChar: String?) {
        showDelayWorkItem?.cancel()
        showDelayWorkItem = nil
        if isPendingShow {
            isPendingShow = false
            showMainPanelNow(sticky: true)
        }
        BrowserTabBridge.shared.refreshTabsAsync()
        state.isStickyMode = true
        mainPanel?.isStickySearchActive = true
        if let ch = initialChar {
            state.searchQuery = ch
            state.selectedWindowIndex = 0
            state.selectedTabIndex = 0
        }
        NSApp.activate(ignoringOtherApps: true)
        mainPanel?.makeKeyAndOrderFront(nil)
        mainPanel?.searchField = state.searchTextField
        mainPanel?.focusSearchField()
    }

    public func closeSelectedWindow() {
        let wins = filteredWindows()
        guard state.selectedWindowIndex >= 0 && state.selectedWindowIndex < wins.count else { return }
        let target = wins[state.selectedWindowIndex]
        WindowEnumerator.shared.closeWindow(target)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { [weak self] in
            guard let self = self else { return }
            let remaining = self.filteredWindows()
            if self.state.selectedWindowIndex >= remaining.count {
                self.state.selectedWindowIndex = max(0, remaining.count - 1)
            }
        }
    }

    public func commitSelectionAndHide() {
        let wins = filteredWindows()
        let tabs = filteredTabs()

        if state.scope == .browserTabs {
            if state.selectedTabIndex >= 0 && state.selectedTabIndex < tabs.count {
                let tab = tabs[state.selectedTabIndex]
                dismissMainGrid(restorePreviousApp: false, immediate: true)
                BrowserTabBridge.shared.activateTab(tab)
                return
            }
        }

        if state.selectedWindowIndex >= 0 && state.selectedWindowIndex < wins.count {
            let win = wins[state.selectedWindowIndex]
            dismissMainGrid(restorePreviousApp: false, immediate: true)
            WindowEnumerator.shared.focusWindow(win)
        } else if !tabs.isEmpty {
            let tabIdx = max(0, min(tabs.count - 1, state.selectedTabIndex))
            let tab = tabs[tabIdx]
            dismissMainGrid(restorePreviousApp: false, immediate: true)
            BrowserTabBridge.shared.activateTab(tab)
        } else {
            dismissMainGrid(restorePreviousApp: true, immediate: false)
        }
    }

    public func selectWindowCard(_ item: WindowCardItem) {
        dismissMainGrid(restorePreviousApp: false, immediate: true)
        onCommitCallback?()
        WindowEnumerator.shared.focusWindow(item)
    }

    public func selectBrowserTab(_ tab: BrowserTabItem) {
        dismissMainGrid(restorePreviousApp: false, immediate: true)
        onCommitCallback?()
        BrowserTabBridge.shared.activateTab(tab)
    }

    public func cancelAndHide() {
        dismissMainGrid(restorePreviousApp: true, immediate: false)
    }

    public func dismissMainGrid(restorePreviousApp: Bool, immediate: Bool = false) {
        showDelayWorkItem?.cancel()
        showDelayWorkItem = nil
        isPendingShow = false
        mainPanelGeneration &+= 1
        let gen = mainPanelGeneration

        guard let panel = mainPanel else {
            state.isStickyMode = false
            state.isPresented = false
            return
        }
        panel.isStickySearchActive = false
        state.isStickyMode = false

        if restorePreviousApp, let prev = previousApp, prev.bundleIdentifier != Bundle.main.bundleIdentifier {
            NSApp.yieldActivation(to: prev)
            prev.activate()
        }

        guard panel.isVisible else {
            state.isPresented = false
            return
        }

        if immediate || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            state.isPresented = false
            panel.orderOut(nil)
            panel.alphaValue = 1.0
            return
        }

        withAnimation(.easeOut(duration: 0.10)) {
            state.isPresented = false
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.10
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0.0
        }, completionHandler: { [weak self] in
            guard let self = self, self.mainPanelGeneration == gen else { return }
            panel.orderOut(nil)
            panel.alphaValue = 1.0
        })
    }

    private func ensureMainPanel() {
        guard mainPanel == nil else { return }
        let panel = SwitcherPanel(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 600),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false // SwiftUI draws tuned multi-layered shadow with continuous radius
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.onEscape = { [weak self] in
            self?.onCommitCallback?()
            self?.cancelAndHide()
        }

        let host = NSHostingView(
            rootView: WindowSwitcherOverlayView(
                controller: self,
                state: state,
                enumerator: .shared,
                tabBridge: .shared
            )
        )
        panel.contentView = host
        self.mainPanel = panel

        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            guard let self = self,
                  self.state.isStickyMode,
                  panel.isVisible else { return }
            self.onCommitCallback?()
            self.dismissMainGrid(restorePreviousApp: false)
        }
    }

    // ─────────────────────────────────────────────────────────────
    // MARK: - Floating Dock Hover Preview Strip
    // ─────────────────────────────────────────────────────────────

    public func presentDockPreview(for app: NSRunningApplication, iconRectAppKit: CGRect) {
        if mainPanel?.isVisible == true && state.isPresented { return }

        // Single-PID AX enumeration (<1ms, zero scanning of unrelated apps)
        let appWindows = WindowEnumerator.shared.refreshWindows(forSingleApp: app, prioritizingApp: previousApp)
        guard !appWindows.isEmpty else {
            dismissDockPreview()
            return
        }

        if CGPreflightScreenCaptureAccess() || WindowEnumerator.shared.hasScreenRecordingPermission {
            WindowEnumerator.shared.captureThumbnailsAsync(for: appWindows, maxThumbWidth: 210)
        }
        dockState.appName = app.localizedName ?? "App"
        dockState.appIcon = app.icon
        dockState.windows = appWindows

        if dockPanel == nil {
            let p = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 210),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            p.isFloatingPanel = true
            p.level = .popUpMenu
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.contentView = NSHostingView(
                rootView: DockPreviewStripView(
                    dockState: dockState,
                    enumerator: .shared,
                    onSelect: { [weak self] win in
                        self?.dismissDockPreview()
                        WindowEnumerator.shared.focusWindow(win)
                    },
                    onCloseWindow: { win in
                        WindowEnumerator.shared.closeWindow(win)
                    }
                )
            )
            dockPanel = p
        }

        guard let strip = dockPanel else { return }
        dockPanelGeneration &+= 1

        let cardCount = min(5, appWindows.count)
        let stripW = CGFloat(cardCount) * 212.0 + CGFloat(max(0, cardCount - 1)) * 10.0 + 48.0
        let stripH: CGFloat = 212.0

        let screen = NSScreen.screens.first(where: { NSPointInRect(CGPoint(x: iconRectAppKit.midX, y: iconRectAppKit.midY), $0.frame) }) ?? NSScreen.main
        let sf = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        var originX = round(iconRectAppKit.midX - stripW / 2.0)
        originX = max(sf.minX + 12.0, min(sf.maxX - stripW - 12.0, originX))
        let originY = min(sf.maxY - stripH - 12.0, iconRectAppKit.maxY + 14.0)
        let targetFrame = NSRect(x: originX, y: originY, width: stripW, height: stripH)

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let wasVisible = strip.isVisible && dockState.isPresented
        if wasVisible {
            if reduceMotion {
                strip.setFrame(targetFrame, display: true)
                strip.alphaValue = 1.0
            } else {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.16
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    strip.animator().setFrame(targetFrame, display: true)
                    strip.animator().alphaValue = 1.0
                }
            }
        } else if reduceMotion {
            strip.setFrame(targetFrame, display: false)
            strip.alphaValue = 1.0
            dockState.isPresented = true
            strip.orderFrontRegardless()
        } else {
            strip.setFrame(targetFrame, display: false)
            strip.alphaValue = 0.0
            dockState.isPresented = false
            strip.orderFrontRegardless()

            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.14
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                strip.animator().alphaValue = 1.0
            }
            withAnimation(.spring(response: 0.22, dampingFraction: 0.84)) {
                dockState.isPresented = true
            }
        }
    }

    public func dismissDockPreview() {
        guard let strip = dockPanel, strip.isVisible else {
            dockState.isPresented = false
            return
        }
        dockPanelGeneration &+= 1
        let gen = dockPanelGeneration

        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            dockState.isPresented = false
            strip.orderOut(nil)
            strip.alphaValue = 1.0
            return
        }

        withAnimation(.easeOut(duration: 0.10)) {
            dockState.isPresented = false
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.10
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            strip.animator().alphaValue = 0.0
        }, completionHandler: { [weak self] in
            guard let self = self, self.dockPanelGeneration == gen else { return }
            strip.orderOut(nil)
            strip.alphaValue = 1.0
        })
    }

    public func isDockPreviewVisible() -> Bool {
        guard let strip = dockPanel else { return false }
        return strip.isVisible && dockState.isPresented
    }

    public func isMouseInsideDockStrip() -> Bool {
        guard let strip = dockPanel, strip.isVisible else { return false }
        let padded = strip.frame.insetBy(dx: -12, dy: -16)
        return NSPointInRect(NSEvent.mouseLocation, padded)
    }
}
