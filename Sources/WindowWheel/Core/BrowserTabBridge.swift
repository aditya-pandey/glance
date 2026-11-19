import AppKit
import Foundation

/// Queries & activates individual tabs inside Chrome, Safari, Arc, and Brave cleanly via AppleScript
public final class BrowserTabBridge: ObservableObject {
    public static let shared = BrowserTabBridge()

    @Published public private(set) var tabs: [BrowserTabItem] = []
    @Published public private(set) var isLoading: Bool = false

    private let queryQueue = DispatchQueue(label: "com.local.Glance.BrowserTabs", qos: .userInitiated)
    private var lastFetchTime: Date = .distantPast

    private init() {}

    public func refreshTabsAsync(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastFetchTime) > 1.5 else { return }
        DispatchQueue.main.async { self.isLoading = true }

        queryQueue.async { [weak self] in
            guard let self = self else { return }
            let fetched = Self.fetchAllRunningBrowserTabs()
            DispatchQueue.main.async {
                self.tabs = fetched
                self.lastFetchTime = Date()
                self.isLoading = false
            }
        }
    }

    public static func fetchAllRunningBrowserTabs() -> [BrowserTabItem] {
        var collected: [BrowserTabItem] = []
        let running = NSWorkspace.shared.runningApplications

        let specs: [(bundleID: String, appName: String, isSafari: Bool)] = [
            ("com.google.Chrome", "Google Chrome", false),
            ("com.apple.Safari", "Safari", true),
            ("company.thebrowser.Browser", "Arc", false),
            ("com.brave.Browser", "Brave Browser", false),
            ("com.microsoft.edgemac", "Microsoft Edge", false)
        ]

        for spec in specs {
            guard let app = running.first(where: { $0.bundleIdentifier == spec.bundleID }) else { continue }
            let icon = app.icon
            let script = spec.isSafari
                ? safariTabScript()
                : chromiumTabScript(appName: spec.appName)

            guard let raw = runAppleScript(script), !raw.isEmpty else { continue }
            let parsed = parseTabLines(raw, browserName: spec.appName, bundleID: spec.bundleID, icon: icon)
            collected.append(contentsOf: parsed)
        }

        return collected
    }

    public static func parseTabLines(
        _ output: String,
        browserName: String,
        bundleID: String,
        icon: NSImage? = nil
    ) -> [BrowserTabItem] {
        var items: [BrowserTabItem] = []
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 5,
                  let wIdx = Int(parts[0]),
                  let tIdx = Int(parts[1]) else { continue }
            let activeFlag = (parts[2] == "1")
            let title = parts[3].trimmingCharacters(in: .whitespacesAndNewlines)
            let url = parts[4].trimmingCharacters(in: .whitespacesAndNewlines)
            let winTitle = parts.count >= 6 ? parts[5].trimmingCharacters(in: .whitespacesAndNewlines) : browserName

            items.append(BrowserTabItem(
                browserName: browserName,
                bundleID: bundleID,
                windowIndex: wIdx,
                tabIndex: tIdx,
                windowTitle: winTitle.isEmpty ? "Window \(wIdx)" : winTitle,
                title: title,
                url: url,
                isActiveInWindow: activeFlag,
                appIcon: icon
            ))
        }
        return items
    }

    public func activateTab(_ tab: BrowserTabItem) {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: tab.bundleID).first {
            NSApp.yieldActivation(to: app)
        }
        let appName = tab.browserName
        let isSafari = (tab.bundleID == "com.apple.Safari")

        let script: String
        if isSafari {
            script = """
            tell application "Safari"
                tell window \(tab.windowIndex)
                    set current tab to tab \(tab.tabIndex)
                end tell
                set index of window \(tab.windowIndex) to 1
                activate
            end tell
            """
        } else {
            script = """
            tell application "\(appName)"
                set active tab index of window \(tab.windowIndex) to \(tab.tabIndex)
                set index of window \(tab.windowIndex) to 1
                activate
            end tell
            """
        }

        queryQueue.async {
            Self.runAppleScript(script)
        }
    }

    public func closeTab(_ tab: BrowserTabItem) {
        let appName = tab.browserName
        let script = """
        tell application "\(appName)"
            close tab \(tab.tabIndex) of window \(tab.windowIndex)
        end tell
        """
        queryQueue.async { [weak self] in
            Self.runAppleScript(script)
            self?.refreshTabsAsync(force: true)
        }
    }

    private static func chromiumTabScript(appName: String) -> String {
        return """
        set outText to ""
        tell application "\(appName)"
            set wCount to count of windows
            repeat with wIdx from 1 to wCount
                set w to window wIdx
                set activeIdx to active tab index of w
                set wName to name of w
                set tIdx to 1
                repeat with t in (tabs of w)
                    set isAct to "0"
                    if tIdx is activeIdx then set isAct to "1"
                    set tTitle to title of t
                    set tURL to URL of t
                    set outText to outText & wIdx & tab & tIdx & tab & isAct & tab & tTitle & tab & tURL & tab & wName & linefeed
                    set tIdx to tIdx + 1
                end repeat
            end repeat
        end tell
        return outText
        """
    }

    private static func safariTabScript() -> String {
        return """
        set outText to ""
        tell application "Safari"
            set wCount to count of windows
            repeat with wIdx from 1 to wCount
                set w to window wIdx
                set curTab to current tab of w
                set wName to name of w
                set tIdx to 1
                repeat with t in (tabs of w)
                    set isAct to "0"
                    if t is curTab then set isAct to "1"
                    set tTitle to name of t
                    set tURL to URL of t
                    set outText to outText & wIdx & tab & tIdx & tab & isAct & tab & tTitle & tab & tURL & tab & wName & linefeed
                    set tIdx to tIdx + 1
                end repeat
            end repeat
        end tell
        return outText
        """
    }

    @discardableResult
    private static func runAppleScript(_ source: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", source]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            return nil
        }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
}
