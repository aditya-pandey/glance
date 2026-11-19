import AppKit
import ApplicationServices
import ScreenCaptureKit
import CoreGraphics

/// Private SPI exported by ApplicationServices (HIServices) to map an AXUIElement directly to its Quartz CGWindowID
@_silgen_name("_AXUIElementGetWindow")
func AXUIElementGetCGWindowID(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

public final class WindowEnumerator: ObservableObject {
    public static let shared = WindowEnumerator()

    @Published public private(set) var windows: [WindowCardItem] = []
    @Published public private(set) var thumbnails: [CGWindowID: NSImage] = [:]
    @Published public private(set) var hasScreenRecordingPermission: Bool = CGPreflightScreenCaptureAccess()
    @Published public private(set) var hasAccessibilityPermission: Bool = AXIsProcessTrusted()
    @Published public private(set) var screenCaptureError: String? = nil

    private var scCaptureConfirmed: Bool = false
    private var lastSCErrorTimestamp: Date? = nil
    private let axQueue = DispatchQueue(label: "com.local.Glance.AXEnum", qos: .userInteractive)
    private var enumerationSessionID: Int = 0

    // Optional runtime SkyLight bridge for exact multi-window focusing (Window B behind Window A)
    private typealias GetProcessForPIDFn = @convention(c) (pid_t, UnsafeMutablePointer<UInt64>) -> OSStatus
    private typealias SLPSSetFrontProcessFn = @convention(c) (UnsafeMutablePointer<UInt64>, CGWindowID, UInt32) -> CGError
    private static let skyLightFocusFns: (getPSN: GetProcessForPIDFn, setFront: SLPSSetFrontProcessFn)? = {
        guard let getSym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "GetProcessForPID"),
              let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let frontSym = dlsym(handle, "_SLPSSetFrontProcessWithOptions") else {
            return nil
        }
        return (
            unsafeBitCast(getSym, to: GetProcessForPIDFn.self),
            unsafeBitCast(frontSym, to: SLPSSetFrontProcessFn.self)
        )
    }()

    public static let browserBundleIDs: Set<String> = [
        "com.google.Chrome",
        "com.apple.Safari",
        "company.thebrowser.Browser", // Arc
        "com.brave.Browser",
        "com.microsoft.edgemac"
    ]

    private init() {}

    public func refreshPermissionFlags() {
        let ax = AXIsProcessTrusted()
        let sc = CGPreflightScreenCaptureAccess() || scCaptureConfirmed
        DispatchQueue.main.async {
            self.hasScreenRecordingPermission = sc
            self.hasAccessibilityPermission = ax
        }
    }

    public func requestPermissions(accessibilityOnly: Bool = false) {
        NSApp.activate(ignoringOtherApps: true)
        let axGranted = AXIsProcessTrusted()
        if !axGranted {
            let axOpts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(axOpts)
        }

        if !accessibilityOnly {
            let granted = CGRequestScreenCaptureAccess()
            if !granted {
                // Trigger SCShareableContent once so macOS Sequoia registers Glance in Privacy_ScreenCapture
                Task.detached {
                    _ = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
                }
                openPrivacyPane(screenRecording: true)
            } else {
                lastSCErrorTimestamp = nil
                scCaptureConfirmed = true
            }
        } else if !axGranted {
            openPrivacyPane(screenRecording: false)
        }
        refreshPermissionFlags()
    }

    public func openPrivacyPane(screenRecording: Bool) {
        let anchor = screenRecording ? "Privacy_ScreenCapture" : "Privacy_Accessibility"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    public func relaunchApplication() {
        let bundleURL = Bundle.main.bundleURL
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = ["-n", bundleURL.path]
        try? proc.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NSApp.terminate(nil)
        }
    }

    // ─────────────────────────────────────────────────────────────
    // MARK: - Instant Window Enumeration (< 5ms)
    // ─────────────────────────────────────────────────────────────

    /// Off-main-thread serial AX enumeration with session-ID staleness guard
    public func refreshWindowsAsync(
        prioritizingApp: NSRunningApplication? = nil,
        completion: (([WindowCardItem]) -> Void)? = nil
    ) {
        enumerationSessionID &+= 1
        let sid = enumerationSessionID
        let runningApps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier
        }
        let targetPID = (prioritizingApp ?? NSWorkspace.shared.frontmostApplication)?.processIdentifier

        axQueue.async { [weak self] in
            guard let self = self else { return }
            let collected = self.collectWindows(for: runningApps, prioritizingPID: targetPID)
            let activeIDs = Set(collected.compactMap { $0.cgWindowID != 0 ? $0.cgWindowID : nil })

            DispatchQueue.main.async {
                guard self.enumerationSessionID == sid else { return }
                self.windows = collected
                if !self.thumbnails.isEmpty {
                    self.thumbnails = self.thumbnails.filter { activeIDs.contains($0.key) }
                }
                completion?(collected)
            }
        }
    }

    public func refreshWindows(prioritizingApp: NSRunningApplication? = nil) -> [WindowCardItem] {
        let runningApps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier
        }
        let targetPID = (prioritizingApp ?? NSWorkspace.shared.frontmostApplication)?.processIdentifier
        let collected = collectWindows(for: runningApps, prioritizingPID: targetPID)
        let activeIDs = Set(collected.compactMap { $0.cgWindowID != 0 ? $0.cgWindowID : nil })

        let updateState = {
            self.windows = collected
            // Prune stale closed-window thumbnails so memory remains tiny (<15 MB)
            if !self.thumbnails.isEmpty {
                self.thumbnails = self.thumbnails.filter { activeIDs.contains($0.key) }
            }
        }
        if Thread.isMainThread { updateState() } else { DispatchQueue.main.async(execute: updateState) }
        return collected
    }

    /// Fast single-PID enumeration for Dock Hover Previews (<1ms, avoids touching unrelated apps)
    public func refreshWindows(forSingleApp app: NSRunningApplication, prioritizingApp: NSRunningApplication? = nil) -> [WindowCardItem] {
        let targetPID = (prioritizingApp ?? NSWorkspace.shared.frontmostApplication)?.processIdentifier
        return collectWindows(for: [app], prioritizingPID: targetPID)
    }

    private func collectWindows(for apps: [NSRunningApplication], prioritizingPID targetPID: pid_t?) -> [WindowCardItem] {
        let axTrusted = AXIsProcessTrusted()
        let scGranted = CGPreflightScreenCaptureAccess() || scCaptureConfirmed
        let setPerms = {
            self.hasAccessibilityPermission = axTrusted
            self.hasScreenRecordingPermission = scGranted
        }
        if Thread.isMainThread { setPerms() } else { DispatchQueue.main.async(execute: setPerms) }

        let allowedPIDs = Set(apps.map { $0.processIdentifier })

        // Build front-to-back on-screen z-order map cleanly via .optionOnScreenOnly
        struct CGWinInfo {
            let id: CGWindowID
            let pid: pid_t
            let title: String
            let bounds: CGRect
            let mruRank: Int
        }

        var onScreenByID: [CGWindowID: CGWinInfo] = [:]
        var allByPID: [pid_t: [CGWinInfo]] = [:]

        if let onScreenList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            for (rank, info) in onScreenList.enumerated() {
                let layer = info[kCGWindowLayer as String] as? Int ?? 0
                guard layer == 0,
                      let wid = info[kCGWindowNumber as String] as? CGWindowID,
                      let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                      allowedPIDs.contains(pid),
                      let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                      let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                      rect.width >= 100 && rect.height >= 60 else { continue }

                let title = (info[kCGWindowName as String] as? String) ?? ""
                let entry = CGWinInfo(id: wid, pid: pid, title: title, bounds: rect, mruRank: rank)
                onScreenByID[wid] = entry
                allByPID[pid, default: []].append(entry)
            }
        }

        if let allList = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            for (rank, info) in allList.enumerated() {
                let layer = info[kCGWindowLayer as String] as? Int ?? 0
                guard layer == 0,
                      let wid = info[kCGWindowNumber as String] as? CGWindowID,
                      let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                      allowedPIDs.contains(pid),
                      onScreenByID[wid] == nil,
                      let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                      let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                      rect.width >= 100 && rect.height >= 60 else { continue }

                let title = (info[kCGWindowName as String] as? String) ?? ""
                allByPID[pid, default: []].append(CGWinInfo(id: wid, pid: pid, title: title, bounds: rect, mruRank: 10000 + rank))
            }
        }

        var collected: [WindowCardItem] = []

        if axTrusted {
            for app in apps {
                let pid = app.processIdentifier
                let appName = app.localizedName ?? "App"
                let bundleID = app.bundleIdentifier ?? appName
                let isCurrent = (pid == targetPID)
                let isBrowser = Self.browserBundleIDs.contains(bundleID)
                let appHidden = app.isHidden

                let appEl = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(appEl, 0.3)

                var windowsObj: AnyObject?
                guard AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &windowsObj) == .success,
                      let axWindows = windowsObj as? [AXUIElement] else { continue }

                for (idx, win) in axWindows.enumerated() {
                    var subroleObj: AnyObject?
                    if AXUIElementCopyAttributeValue(win, kAXSubroleAttribute as CFString, &subroleObj) == .success,
                       let subrole = subroleObj as? String,
                       !subrole.isEmpty,
                       subrole != (kAXStandardWindowSubrole as String) && subrole != (kAXDialogSubrole as String) {
                        continue
                    }

                    var rect = CGRect.zero
                    var posObj: AnyObject?
                    var sizeObj: AnyObject?
                    if AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &posObj) == .success,
                       AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &sizeObj) == .success {
                        var pt = CGPoint.zero
                        var sz = CGSize.zero
                        AXValueGetValue(posObj as! AXValue, .cgPoint, &pt)
                        AXValueGetValue(sizeObj as! AXValue, .cgSize, &sz)
                        rect = CGRect(origin: pt, size: sz)
                        if rect.width < 100 || rect.height < 60 { continue }
                    }

                    var titleObj: AnyObject?
                    _ = AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &titleObj)
                    let rawTitle = (titleObj as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                    var minObj: AnyObject?
                    _ = AXUIElementCopyAttributeValue(win, kAXMinimizedAttribute as CFString, &minObj)
                    let isMin = (minObj as? Bool) ?? false

                    // Map directly to CGWindowID via _AXUIElementGetWindow (or fallback by title/frame match)
                    var wid: CGWindowID = 0
                    if AXUIElementGetCGWindowID(win, &wid) != .success || wid == 0 {
                        if let matched = allByPID[pid]?.first(where: {
                            (!rawTitle.isEmpty && $0.title == rawTitle) ||
                            (abs($0.bounds.origin.x - rect.origin.x) < 4 && abs($0.bounds.width - rect.width) < 4)
                        }) {
                            wid = matched.id
                        }
                    }

                    let cleanTitle = rawTitle.isEmpty ? appName : rawTitle
                    let onScreenRank = (!isMin && !appHidden) ? onScreenByID[wid]?.mruRank : nil
                    let mru = onScreenRank ?? (10000 + idx)

                    collected.append(WindowCardItem(
                        id: wid != 0 ? "wid-\(wid)" : "ax-\(pid)-\(idx)-\(cleanTitle)",
                        cgWindowID: wid,
                        pid: pid,
                        bundleID: bundleID,
                        appName: appName,
                        title: cleanTitle,
                        frame: rect,
                        isMinimized: isMin,
                        isHidden: appHidden,
                        isCurrentApp: isCurrent,
                        isBrowser: isBrowser,
                        mruRank: mru,
                        axWindow: win,
                        appIcon: app.icon
                    ))
                }
            }
        } else {
            // Graceful fallback even before Accessibility is granted: enumerate from WindowServer list!
            for info in onScreenByID.values {
                guard let app = apps.first(where: { $0.processIdentifier == info.pid }) else { continue }
                let appName = app.localizedName ?? "App"
                let bundleID = app.bundleIdentifier ?? appName
                let title = info.title.isEmpty ? appName : info.title

                collected.append(WindowCardItem(
                    id: "wid-\(info.id)",
                    cgWindowID: info.id,
                    pid: info.pid,
                    bundleID: bundleID,
                    appName: appName,
                    title: title,
                    frame: info.bounds,
                    isMinimized: false,
                    isHidden: app.isHidden,
                    isCurrentApp: info.pid == targetPID,
                    isBrowser: Self.browserBundleIDs.contains(bundleID),
                    mruRank: info.mruRank,
                    axWindow: nil,
                    appIcon: app.icon
                ))
            }
        }

        // Front-to-back on-screen windows first; minimized and hidden windows sorted cleanly after
        collected.sort { a, b in
            let aOnScreen = !a.isMinimized && !a.isHidden && a.mruRank < 10000
            let bOnScreen = !b.isMinimized && !b.isHidden && b.mruRank < 10000
            if aOnScreen != bOnScreen { return aOnScreen }
            if aOnScreen && a.mruRank != b.mruRank { return a.mruRank < b.mruRank }
            if a.appName != b.appName { return a.appName.localizedCaseInsensitiveCompare(b.appName) == .orderedAscending }
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
        return collected
    }

    // ─────────────────────────────────────────────────────────────
    // MARK: - Live Hardware Thumbnail Capture (ScreenCaptureKit)
    // ─────────────────────────────────────────────────────────────

    public func captureThumbnailsAsync(for items: [WindowCardItem], maxThumbWidth: Int = 260, forceProbe: Bool = false) {
        if !forceProbe, !CGPreflightScreenCaptureAccess(), !scCaptureConfirmed,
           let lastErr = lastSCErrorTimestamp, Date().timeIntervalSince(lastErr) < 2.5 {
            return
        }

        let orderedIDs = items.filter { $0.cgWindowID != 0 && !$0.isMinimized }.map { $0.cgWindowID }
        guard !orderedIDs.isEmpty else { return }
        let orderIndex = Dictionary(uniqueKeysWithValues: orderedIDs.enumerated().map { ($1, $0) })
        let targetIDs = Set(orderedIDs)
        let backingScale = NSScreen.screens.first(where: { NSPointInRect(NSEvent.mouseLocation, $0.frame) })?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2.0

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            let content: SCShareableContent
            do {
                content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            } catch {
                let errDesc = error.localizedDescription
                await MainActor.run {
                    self.scCaptureConfirmed = false
                    self.lastSCErrorTimestamp = Date()
                    self.hasScreenRecordingPermission = CGPreflightScreenCaptureAccess()
                    self.screenCaptureError = errDesc
                }
                return
            }

            let matchingSCWindows = content.windows
                .filter { targetIDs.contains($0.windowID) && $0.frame.width > 10 && $0.frame.height > 10 }
                .sorted { (orderIndex[$0.windowID] ?? Int.max) < (orderIndex[$1.windowID] ?? Int.max) }

            await MainActor.run {
                self.scCaptureConfirmed = true
                self.lastSCErrorTimestamp = nil
                self.hasScreenRecordingPermission = true
                self.screenCaptureError = nil
            }

            // Bounded concurrency (max 6 concurrent captures in display order)
            await withTaskGroup(of: (CGWindowID, CGImage)?.self) { group in
                let maxConcurrent = 6
                var nextIdx = 0

                func enqueueNext() {
                    guard nextIdx < matchingSCWindows.count else { return }
                    let scWin = matchingSCWindows[nextIdx]
                    nextIdx += 1
                    group.addTask {
                        let filter = SCContentFilter(desktopIndependentWindow: scWin)
                        let cfg = SCStreamConfiguration()
                        let aspect = scWin.frame.height > 10 ? (scWin.frame.width / scWin.frame.height) : 1.6
                        let pixelW = max(240, Int(round(Double(maxThumbWidth) * backingScale)))
                        let pixelH = max(140, Int(round(Double(pixelW) / max(0.5, min(2.8, aspect)))))
                        cfg.width = pixelW
                        cfg.height = pixelH
                        cfg.showsCursor = false
                        cfg.ignoreShadowsSingleWindow = true
                        cfg.scalesToFit = true
                        cfg.captureResolution = .best

                        guard let cgImg = try? await SCScreenshotManager.captureImage(
                            contentFilter: filter,
                            configuration: cfg
                        ) else {
                            return nil
                        }
                        return (scWin.windowID, cgImg)
                    }
                }

                for _ in 0..<min(maxConcurrent, matchingSCWindows.count) {
                    enqueueNext()
                }

                for await pair in group {
                    enqueueNext()
                    if let (wid, cgImg) = pair {
                        await MainActor.run {
                            self.thumbnails[wid] = NSImage(
                                cgImage: cgImg,
                                size: NSSize(width: cgImg.width, height: cgImg.height)
                            )
                        }
                    }
                }
            }
        }
    }

    // ─────────────────────────────────────────────────────────────
    // MARK: - Window Control Actions (Focus, Close, Minimize, Snap)
    // ─────────────────────────────────────────────────────────────

    public func focusWindow(_ item: WindowCardItem) {
        guard let app = NSRunningApplication(processIdentifier: item.pid) else { return }
        if item.isHidden || app.isHidden {
            app.unhide()
        }
        if item.cgWindowID != 0, let sky = Self.skyLightFocusFns {
            var psn: UInt64 = 0
            if sky.getPSN(item.pid, &psn) == noErr {
                _ = sky.setFront(&psn, item.cgWindowID, 0x200)
            }
        }
        if let axWin = item.axWindow {
            if item.isMinimized {
                AXUIElementSetAttributeValue(axWin, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            }
            AXUIElementPerformAction(axWin, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(axWin, kAXMainAttribute as CFString, kCFBooleanTrue)
        }
        NSApp.yieldActivation(to: app)
        app.activate()
        if let axWin = item.axWindow {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                AXUIElementPerformAction(axWin, kAXRaiseAction as CFString)
            }
        }
    }

    public func closeWindow(_ item: WindowCardItem) {
        guard let axWin = item.axWindow else { return }
        var closeBtnObj: AnyObject?
        if AXUIElementCopyAttributeValue(axWin, kAXCloseButtonAttribute as CFString, &closeBtnObj) == .success,
           let closeBtn = closeBtnObj {
            AXUIElementPerformAction(closeBtn as! AXUIElement, kAXPressAction as CFString)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { [weak self] in
                _ = self?.refreshWindows()
            }
        }
    }

    public func minimizeWindow(_ item: WindowCardItem) {
        guard let axWin = item.axWindow else { return }
        let newValue: CFBoolean = item.isMinimized ? kCFBooleanFalse : kCFBooleanTrue
        AXUIElementSetAttributeValue(axWin, kAXMinimizedAttribute as CFString, newValue)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            _ = self?.refreshWindows()
        }
    }

    public enum TileMode { case leftHalf, rightHalf, maximize }

    public func snapWindow(_ item: WindowCardItem, mode: TileMode) {
        guard let axWin = item.axWindow,
              let screen = NSScreen.screens.first(where: { NSPointInRect(NSEvent.mouseLocation, $0.frame) }) ?? NSScreen.main else {
            return
        }
        let visible = screen.visibleFrame
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height

        let targetRect: CGRect
        switch mode {
        case .leftHalf:
            targetRect = CGRect(x: visible.minX, y: visible.minY, width: floor(visible.width / 2), height: visible.height)
        case .rightHalf:
            let half = floor(visible.width / 2)
            targetRect = CGRect(x: visible.minX + half, y: visible.minY, width: visible.width - half, height: visible.height)
        case .maximize:
            targetRect = visible
        }

        var origin = CGPoint(x: targetRect.origin.x, y: primaryHeight - targetRect.maxY)
        var size = targetRect.size

        if item.isMinimized {
            AXUIElementSetAttributeValue(axWin, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        if let oVal = AXValueCreate(.cgPoint, &origin),
           let sVal = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(axWin, kAXPositionAttribute as CFString, oVal)
            AXUIElementSetAttributeValue(axWin, kAXSizeAttribute as CFString, sVal)
            AXUIElementSetAttributeValue(axWin, kAXPositionAttribute as CFString, oVal)
            AXUIElementPerformAction(axWin, kAXRaiseAction as CFString)
        }
        NSRunningApplication(processIdentifier: item.pid)?.activate()
    }
}
