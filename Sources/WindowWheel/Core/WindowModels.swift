import AppKit
import ApplicationServices

public enum SwitcherScope: String, CaseIterable, Identifiable {
    case allWindows = "All Windows"
    case currentApp = "Current App"
    case browserTabs = "Browser Tabs"

    public var id: String { rawValue }
}

public struct WindowCardItem: Identifiable, Equatable {
    public let id: String
    public let cgWindowID: CGWindowID
    public let pid: pid_t
    public let bundleID: String
    public let appName: String
    public let title: String
    public let frame: CGRect
    public let isMinimized: Bool
    public let isHidden: Bool
    public let isCurrentApp: Bool
    public let isBrowser: Bool
    public let mruRank: Int
    public let axWindow: AXUIElement?
    public let appIcon: NSImage?

    public init(
        id: String,
        cgWindowID: CGWindowID,
        pid: pid_t,
        bundleID: String,
        appName: String,
        title: String,
        frame: CGRect = .zero,
        isMinimized: Bool = false,
        isHidden: Bool = false,
        isCurrentApp: Bool = false,
        isBrowser: Bool = false,
        mruRank: Int = 9999,
        axWindow: AXUIElement? = nil,
        appIcon: NSImage? = nil
    ) {
        self.id = id
        self.cgWindowID = cgWindowID
        self.pid = pid
        self.bundleID = bundleID
        self.appName = appName
        self.title = title
        self.frame = frame
        self.isMinimized = isMinimized
        self.isHidden = isHidden
        self.isCurrentApp = isCurrentApp
        self.isBrowser = isBrowser
        self.mruRank = mruRank
        self.axWindow = axWindow
        self.appIcon = appIcon
    }

    public static func == (lhs: WindowCardItem, rhs: WindowCardItem) -> Bool {
        lhs.id == rhs.id
            && lhs.cgWindowID == rhs.cgWindowID
            && lhs.title == rhs.title
            && lhs.isMinimized == rhs.isMinimized
            && lhs.isHidden == rhs.isHidden
    }
}

public struct BrowserTabItem: Identifiable, Equatable {
    public let id: String
    public let browserName: String
    public let bundleID: String
    public let windowIndex: Int     // 1-based AppleScript window index
    public let tabIndex: Int        // 1-based AppleScript tab index
    public let windowTitle: String
    public let title: String
    public let url: String
    public let domain: String
    public let isActiveInWindow: Bool
    public let appIcon: NSImage?

    public init(
        browserName: String,
        bundleID: String,
        windowIndex: Int,
        tabIndex: Int,
        windowTitle: String,
        title: String,
        url: String,
        isActiveInWindow: Bool = false,
        appIcon: NSImage? = nil
    ) {
        self.id = "\(bundleID)-w\(windowIndex)-t\(tabIndex)"
        self.browserName = browserName
        self.bundleID = bundleID
        self.windowIndex = windowIndex
        self.tabIndex = tabIndex
        self.windowTitle = windowTitle
        self.title = title.isEmpty ? url : title
        self.url = url
        self.domain = Self.extractDomain(from: url)
        self.isActiveInWindow = isActiveInWindow
        self.appIcon = appIcon
    }

    public static func extractDomain(from rawURL: String) -> String {
        guard let host = URL(string: rawURL)?.host else { return "" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
