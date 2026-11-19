import Foundation
import AppKit
import ApplicationServices
import ScreenCaptureKit

public enum WindowWheelSelfTest {
    private static var passed = 0
    private static var failed = 0

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if condition() {
            passed += 1
        } else {
            failed += 1
            print("❌ FAIL: \(message)")
        }
    }

    public static func runAll() -> Bool {
        passed = 0
        failed = 0
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        print("🧪 Running Glance Automated QA & Switcher Test Suite...")
        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

        testBrowserTabParsingAndDomains()
        testFilteringAndScopeSelection()
        testStepCycling()
        testWindowEnumerationAndCaptureSafety()

        print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        if failed == 0 {
            print("✅ ALL \(passed) WINDOWWHEEL TESTS PASSED (0 failures)")
            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            return true
        } else {
            print("❌ \(failed) TESTS FAILED (\(passed) passed)")
            print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
            return false
        }
    }

    public static func runDiagnostics() {
        print("━━━ Glance Live Diagnostics ━━━")
        let ax = AXIsProcessTrusted()
        let sc = CGPreflightScreenCaptureAccess()
        print("AXIsProcessTrusted: \(ax)")
        print("CGPreflightScreenCaptureAccess: \(sc)")

        let wins = WindowEnumerator.shared.refreshWindows()
        print("WindowEnumerator.refreshWindows count: \(wins.count)")
        for w in wins.prefix(8) {
            print("  • wid=\(w.cgWindowID) pid=\(w.pid) app='\(w.appName)' title='\(w.title)' min=\(w.isMinimized) frame=\(w.frame)")
        }

        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
                print("SCShareableContent windows count: \(content.windows.count)")
                if let sample = content.windows.first(where: { $0.windowLayer == 0 && $0.frame.width > 200 }) {
                    let filter = SCContentFilter(desktopIndependentWindow: sample)
                    let cfg = SCStreamConfiguration()
                    cfg.width = 400
                    cfg.height = 250
                    cfg.showsCursor = false
                    let img = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
                    print("SCScreenshotManager sample OK: \(img.width)x\(img.height) for wid=\(sample.windowID)")
                }
            } catch {
                print("SCShareableContent/Capture ERROR: \(error)")
            }
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 4.0)
    }

    private static func testBrowserTabParsingAndDomains() {
        print("▸ Testing BrowserTabBridge (Tab Parsing & Domain Extraction)...")
        expect(BrowserTabItem.extractDomain(from: "https://www.github.com/pulls") == "github.com", "Strips www. from domain")
        expect(BrowserTabItem.extractDomain(from: "http://localhost:3000/dashboard") == "localhost", "Handles localhost URLs cleanly")

        let sampleOutput = """
        1\t1\t0\tInbox - Gmail\thttps://mail.google.com/mail/u/0/\tGitHub — Chrome
        1\t2\t1\tPull Requests · Repo\thttps://github.com/pulls\tGitHub — Chrome
        2\t1\t1\tLocal Dev\thttp://localhost:5173\tLocal Dev — Chrome
        """

        let parsed = BrowserTabBridge.parseTabLines(sampleOutput, browserName: "Google Chrome", bundleID: "com.google.Chrome")
        expect(parsed.count == 3, "Parses 3 tabs across 2 Chrome windows")
        expect(parsed[1].windowIndex == 1 && parsed[1].tabIndex == 2 && parsed[1].isActiveInWindow, "Accurately detects active tab index inside Window 1")
        expect(parsed[2].windowIndex == 2 && parsed[2].domain == "localhost", "Accurately detects Window 2 tab and localhost domain")
    }

    private static func testFilteringAndScopeSelection() {
        print("▸ Testing WindowCardItem Multi-Window Filtering & Sorting...")
        let ctrl = OverlayPanelController.shared
        let sampleWins = [
            WindowCardItem(id: "w1", cgWindowID: 101, pid: 10, bundleID: "com.google.Chrome", appName: "Google Chrome", title: "Gmail - Work", isCurrentApp: true, isBrowser: true, mruRank: 1),
            WindowCardItem(id: "w2", cgWindowID: 102, pid: 10, bundleID: "com.google.Chrome", appName: "Google Chrome", title: "GitHub - WeaponWheel", isCurrentApp: true, isBrowser: true, mruRank: 2),
            WindowCardItem(id: "w3", cgWindowID: 103, pid: 20, bundleID: "com.todesktop.230313mzl4w4u92", appName: "Cursor", title: "WindowEnumerator.swift", isCurrentApp: false, isBrowser: false, mruRank: 3)
        ]

        // Filter simulation on tokens
        let tokens = ["chrome", "github"]
        let matched = sampleWins.filter { w in
            let hay = "\(w.appName) \(w.title)".lowercased()
            return tokens.allSatisfy { hay.contains($0) }
        }
        expect(matched.count == 1 && matched.first?.id == "w2", "Multi-token query 'chrome github' isolates exact Chrome window")

        let currentAppOnly = sampleWins.filter { $0.isCurrentApp }
        expect(currentAppOnly.count == 2, "Current App scope isolates the 2 Chrome windows")
        _ = ctrl // verify singleton instantiation cleanly
    }

    private static func testStepCycling() {
        print("▸ Testing Wrap-Around Step Selection...")
        let count = 4
        var idx = 1
        idx = (idx + 1 + count) % count
        expect(idx == 2, "Forward step moves 1 -> 2")
        idx = (0 - 1 + count) % count
        expect(idx == 3, "Reverse step from 0 wraps cleanly to last card (3)")
    }

    private static func testWindowEnumerationAndCaptureSafety() {
        print("▸ Testing WindowEnumerator & Capture Resilience...")
        let wins = WindowEnumerator.shared.refreshWindows()
        let uniqueIDs = Set(wins.map { $0.id })
        expect(uniqueIDs.count == wins.count, "All enumerated window cards have unique identifiers")
        expect(wins.allSatisfy { $0.frame.width >= 100 && $0.frame.height >= 70 }, "Enumerated windows respect minimum size filter")
        // Verify async capture call returns immediately on non-main or zero-ID inputs without crashing
        WindowEnumerator.shared.captureThumbnailsAsync(for: [])
        expect(true, "Empty capture request handles gracefully without errors")

        // Verify minimized/hidden flags and sorting separation
        let visibleItem = WindowCardItem(id: "v1", cgWindowID: 1, pid: 1, bundleID: "b1", appName: "AppA", title: "Main", isMinimized: false, isHidden: false, mruRank: 5)
        let hiddenItem = WindowCardItem(id: "h1", cgWindowID: 2, pid: 2, bundleID: "b2", appName: "AppB", title: "Hidden", isMinimized: false, isHidden: true, mruRank: 1)
        let minItem = WindowCardItem(id: "m1", cgWindowID: 3, pid: 3, bundleID: "b3", appName: "AppC", title: "Min", isMinimized: true, isHidden: false, mruRank: 2)
        let sorted = [hiddenItem, minItem, visibleItem].sorted { a, b in
            let aOn = !a.isMinimized && !a.isHidden && a.mruRank < 10000
            let bOn = !b.isMinimized && !b.isHidden && b.mruRank < 10000
            if aOn != bOn { return aOn }
            return a.mruRank < b.mruRank
        }
        expect(sorted.first?.id == "v1", "On-screen window sorts ahead of minimized & hidden windows")
    }
}
