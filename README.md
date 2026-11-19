# Glance

A native macOS menu-bar utility that brings fast, visual **live window & browser tab previews** (`⌥ Tab`), **same-app window switching** (`⌥ ~`), and **Dock icon hover previews** to macOS 14.0+.

Built strictly with native Apple frameworks (**Swift, SwiftUI, AppKit, ScreenCaptureKit, ApplicationServices, Carbon, ServiceManagement**) — zero third-party dependencies, zero telemetry, zero idle background polling.

---

## Shortcuts & Gestures

| Action | Result |
|---|---|
| **Tap `Option + Tab`** (`< 150 ms`) | Flips immediately to your previous window with zero HUD flash |
| **Hold `Option + Tab`** | Opens the live preview grid across all open windows (`Release ⌥` to switch) |
| **`Option + ~`** | Opens the live preview grid filtered to **windows of the current app** (e.g. multiple Chrome or Finder windows) |
| **`Option + Shift + Tab`** / **Arrow keys** | Cycles backward or navigates the grid |
| **Hover Dock icon** | Pops a floating taskbar-style preview strip above the Dock icon (dismisses immediately on click or right-click Dock menus) |
| **Type any letter or `/`** | Locks the HUD into **Pinned Search** to filter windows and open Chrome/Safari/Arc/Brave/Edge tabs |
| **`Q` / `⌘ W`** | Closes the selected window without leaving the switcher |
| **`Escape`** | Dismisses without switching |

---

## Requirements

- **macOS 14.0 (Sonoma)** or newer
- **Xcode** or **Xcode Command Line Tools** (to build from source)

---

## Build & Install

```bash
cd window_wheel
./build_app.sh
open /Applications/Glance.app
```

`build_app.sh` compiles in release mode, runs the automated test suite (`--self-test`), assembles `Glance.app`, signs it, installs it to `/Applications/Glance.app`, and registers it with LaunchServices.

---

## Code Signing (Preserve Permissions Across Rebuilds)

macOS binds **Accessibility** and **Screen Recording** grants to the app's code signature. `build_app.sh` automatically selects a signing identity in this order:
1. `GLANCE_SIGN_IDENTITY` (or `WINDOWWHEEL_SIGN_IDENTITY`) environment variable
2. A Keychain certificate matching `Apple Development`, `Glance Local`, or `WindowWheel Local`
3. Ad-hoc (`-`), which requires re-granting permissions after rebuilds

To create a one-time local certificate so permissions persist across rebuilds:
1. Open `/System/Library/CoreServices/Certificate Assistant.app`.
2. Set **Name:** `Glance Local`, **Identity Type:** `Self-Signed Root`, **Certificate Type:** `Code Signing`, then click **Create**.
3. Run `./build_app.sh` (click **Always Allow** if `codesign` prompts for Keychain access).

---

## Permissions

On first launch (or from the Menu Bar icon → **Permissions…**):
- **Accessibility:** Required to focus/raise/close windows, intercept switcher keys, and detect Dock icon hover.
- **Screen & System Audio Recording:** Required by ScreenCaptureKit to render live window thumbnails (cards gracefully fall back to app icons when disabled). Click **Relaunch** in Glance after toggling Screen Recording ON.
- **Automation (Optional):** Requested only when opening **Browser Tabs** or **Search** to list and jump to individual Chrome, Safari, Arc, Brave, or Edge tabs.

---

## Project Layout

```text
window_wheel/
├── Package.swift
├── build_app.sh
├── Assets/LogoKit/                 # Focal Frame SVG masters, AppIcon.icns, MenuBarTemplate, exports
└── Sources/WindowWheel/
    ├── main.swift                  # Entry point (--self-test, --diag)
    ├── AppDelegate.swift           # Menu bar status item, Launch at Login, lifecycle
    ├── Core/
    │   ├── WindowModels.swift      # WindowCardItem, BrowserTabItem, SwitcherScope
    │   ├── WindowTheme.swift       # Space Black & Brushed Titanium + NSVisualEffectView wrapper
    │   ├── WindowEnumerator.swift  # Off-main-thread AX enumeration, SkyLight focus & ScreenCaptureKit
    │   ├── HotkeyManager.swift     # Carbon global triggers + active-session CGEventTap
    │   ├── DockHoverMonitor.swift  # Dock AX hover monitor & click/menu overlap guard
    │   ├── BrowserTabBridge.swift  # On-demand AppleScript browser tab listing & activation
    │   └── WindowWheelSelfTest.swift
    └── UI/
        ├── OverlayPanelController.swift
        ├── WindowSwitcherOverlayView.swift
        ├── DockPreviewStripView.swift
        └── PermissionsWindowController.swift
```
