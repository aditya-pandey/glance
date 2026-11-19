import AppKit
import ApplicationServices

/// Monitors cursor hovering over macOS Dock app icons and pops a Windows-style taskbar thumbnail strip
public final class DockHoverMonitor {
    public static let shared = DockHoverMonitor()

    public var isEnabled: Bool = true {
        didSet {
            if isEnabled { start() } else { stop(); onDismissStrip?() }
        }
    }

    public var onHoverApp: ((_ app: NSRunningApplication, _ dockIconFrameAppKit: CGRect) -> Void)?
    public var onDismissStrip: (() -> Void)?
    public var isMouseOverStrip: (() -> Bool)?
    public var isStripVisible: (() -> Bool)?

    private var mouseMoveMonitor: Any?
    private var mouseClickMonitor: Any?
    private var screenObserver: NSObjectProtocol?
    private var cachedScreenFrames: [CGRect] = []
    private var primaryScreenHeight: CGFloat = 900
    private var hoverTimer: Timer?
    private var dismissTimer: Timer?
    private var lastHoveredPID: pid_t? = nil
    private var suppressUntil: Date = .distantPast

    private init() {
        refreshScreenCache()
    }

    public func start() {
        stop()
        guard isEnabled else { return }

        refreshScreenCache()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshScreenCache()
        }

        mouseMoveMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            self?.handleMouseMoved(to: NSEvent.mouseLocation)
        }

        mouseClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self = self else { return }
            let overStrip = (self.isMouseOverStrip?() == true)
            // Dismiss immediately on any click outside our strip, or any right-click (e.g. Dock context menu)
            if !overStrip || event.type == .rightMouseDown || event.modifierFlags.contains(.control) {
                self.suppressUntil = Date().addingTimeInterval(0.75)
                self.dismissImmediately()
            }
        }
    }

    public func stop() {
        if let m = mouseMoveMonitor { NSEvent.removeMonitor(m); mouseMoveMonitor = nil }
        if let c = mouseClickMonitor { NSEvent.removeMonitor(c); mouseClickMonitor = nil }
        if let obs = screenObserver { NotificationCenter.default.removeObserver(obs); screenObserver = nil }
        hoverTimer?.invalidate(); hoverTimer = nil
        dismissTimer?.invalidate(); dismissTimer = nil
        lastHoveredPID = nil
    }

    private func dismissImmediately() {
        hoverTimer?.invalidate(); hoverTimer = nil
        dismissTimer?.invalidate(); dismissTimer = nil
        lastHoveredPID = nil
        onDismissStrip?()
    }

    private func refreshScreenCache() {
        cachedScreenFrames = NSScreen.screens.map { $0.frame }
        primaryScreenHeight = NSScreen.screens.first?.frame.height ?? 900
    }

    private func handleMouseMoved(to appKitPoint: CGPoint) {
        guard isEnabled else { return }
        if Date() < suppressUntil { return }

        // If mouse is currently inside our floating Dock Preview Strip, keep it open!
        if isMouseOverStrip?() == true {
            dismissTimer?.invalidate()
            dismissTimer = nil
            return
        }

        // Fast spatial guard using cached screen rects (zero NSScreen allocations at 120Hz)
        guard isNearDockEdge(appKitPoint) else {
            scheduleDismissIfNeeded()
            return
        }

        hoverTimer?.invalidate()
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.11, repeats: false) { [weak self] _ in
            self?.inspectDockIcon(at: NSEvent.mouseLocation)
        }
    }

    private func isNearDockEdge(_ pt: CGPoint) -> Bool {
        for f in cachedScreenFrames {
            guard NSPointInRect(pt, f) else { continue }
            if pt.y <= f.minY + 105.0 || pt.x <= f.minX + 95.0 || pt.x >= f.maxX - 95.0 {
                return true
            }
        }
        return false
    }

    private func inspectDockIcon(at appKitPoint: CGPoint) {
        guard AXIsProcessTrusted() else { return }
        if Date() < suppressUntil { return }
        if isMouseOverStrip?() == true { return }

        let primaryHeight = primaryScreenHeight
        let cgPoint = CGPoint(x: appKitPoint.x, y: primaryHeight - appKitPoint.y)

        let systemWide = AXUIElementCreateSystemWide()
        var elementObj: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(cgPoint.x), Float(cgPoint.y), &elementObj) == .success,
              let el = elementObj else {
            scheduleDismissIfNeeded()
            return
        }

        var pid: pid_t = 0
        AXUIElementGetPid(el, &pid)
        guard let dockOwner = NSRunningApplication(processIdentifier: pid),
              dockOwner.bundleIdentifier == "com.apple.dock" else {
            scheduleDismissIfNeeded()
            return
        }

        // If macOS Dock context menu (Options / Quit / Windows list) is open, dismiss immediately so menus never overlap
        if isDockContextMenuOpen(dockPid: pid, hitElement: el) {
            dismissImmediately()
            return
        }

        guard let dockItem = findApplicationDockItem(startingAt: el) else {
            scheduleDismissIfNeeded()
            return
        }

        var urlObj: AnyObject?
        var dockBundleURL: URL? = nil
        if AXUIElementCopyAttributeValue(dockItem, kAXURLAttribute as CFString, &urlObj) == .success {
            dockBundleURL = (urlObj as? URL)?.standardizedFileURL
        }

        var titleObj: AnyObject?
        _ = AXUIElementCopyAttributeValue(dockItem, kAXTitleAttribute as CFString, &titleObj)
        let appTitle = (titleObj as? String) ?? ""

        // Match to a running regular app by bundleURL first, then localizedName
        let targetApp = NSWorkspace.shared.runningApplications.first(where: { app in
            guard app.activationPolicy == .regular,
                  app.bundleIdentifier != Bundle.main.bundleIdentifier else { return false }
            if let dockURL = dockBundleURL, let appURL = app.bundleURL?.standardizedFileURL, dockURL == appURL {
                return true
            }
            return !appTitle.isEmpty && app.localizedName?.localizedCaseInsensitiveCompare(appTitle) == .orderedSame
        })

        guard let targetApp else {
            scheduleDismissIfNeeded()
            return
        }

        // Get icon frame in AppKit screen coordinates to anchor our strip directly above it
        var iconRect = CGRect(x: appKitPoint.x - 30, y: appKitPoint.y - 30, width: 60, height: 60)
        var posObj: AnyObject?
        var sizeObj: AnyObject?
        if AXUIElementCopyAttributeValue(dockItem, kAXPositionAttribute as CFString, &posObj) == .success,
           AXUIElementCopyAttributeValue(dockItem, kAXSizeAttribute as CFString, &sizeObj) == .success {
            var pt = CGPoint.zero
            var sz = CGSize.zero
            AXValueGetValue(posObj as! AXValue, .cgPoint, &pt)
            AXValueGetValue(sizeObj as! AXValue, .cgSize, &sz)
            iconRect = CGRect(x: pt.x, y: primaryHeight - pt.y - sz.height, width: sz.width, height: sz.height)
        }

        dismissTimer?.invalidate()
        dismissTimer = nil

        let stripAlreadyOpen = (isStripVisible?() == true)
        if lastHoveredPID == targetApp.processIdentifier && stripAlreadyOpen {
            return
        }
        lastHoveredPID = targetApp.processIdentifier
        onHoverApp?(targetApp, iconRect)
    }

    private func isDockContextMenuOpen(dockPid: pid_t, hitElement: AXUIElement) -> Bool {
        var roleObj: AnyObject?
        if AXUIElementCopyAttributeValue(hitElement, kAXRoleAttribute as CFString, &roleObj) == .success,
           let role = roleObj as? String,
           (role == kAXMenuRole as String || role == kAXMenuItemRole as String) {
            return true
        }
        let dockAppEl = AXUIElementCreateApplication(dockPid)
        AXUIElementSetMessagingTimeout(dockAppEl, 0.15)
        var childrenObj: AnyObject?
        if AXUIElementCopyAttributeValue(dockAppEl, kAXChildrenAttribute as CFString, &childrenObj) == .success,
           let children = childrenObj as? [AXUIElement] {
            for child in children {
                var childRoleObj: AnyObject?
                if AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &childRoleObj) == .success,
                   let r = childRoleObj as? String,
                   r == kAXMenuRole as String {
                    return true
                }
            }
        }
        return false
    }

    private func findApplicationDockItem(startingAt element: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = element
        for _ in 0..<5 {
            guard let el = current else { return nil }
            var subroleObj: AnyObject?
            if AXUIElementCopyAttributeValue(el, kAXSubroleAttribute as CFString, &subroleObj) == .success,
               let subrole = subroleObj as? String,
               subrole == "AXApplicationDockItem" {
                return el
            }
            var parentObj: AnyObject?
            if AXUIElementCopyAttributeValue(el, kAXParentAttribute as CFString, &parentObj) == .success,
               let parent = parentObj {
                current = (parent as! AXUIElement)
            } else {
                return nil
            }
        }
        return nil
    }

    private func scheduleDismissIfNeeded() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        guard lastHoveredPID != nil, dismissTimer == nil else { return }

        dismissTimer = Timer.scheduledTimer(withTimeInterval: 0.24, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.dismissTimer = nil
            if self.isMouseOverStrip?() == true { return }
            self.lastHoveredPID = nil
            self.onDismissStrip?()
        }
    }
}
