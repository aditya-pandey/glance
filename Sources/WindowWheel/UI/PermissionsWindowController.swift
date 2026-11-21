import AppKit
import SwiftUI
import ServiceManagement

/// Compact Permissions & Onboarding window with live 1-second Accessibility, Screen Recording, and Launch at Login polling
public final class PermissionsWindowController: NSObject, NSWindowDelegate {
    public static let shared = PermissionsWindowController()

    private var window: NSWindow?
    private var pollTimer: Timer?
    private let loginStatusModel = LoginItemStatusModel()

    private override init() { super.init() }

    public func show() {
        if window == nil {
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 308),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            win.title = "Glance Permissions"
            win.titlebarAppearsTransparent = true
            win.isMovableByWindowBackground = true
            win.isReleasedWhenClosed = false
            win.center()
            win.delegate = self
            win.backgroundColor = NSColor(red: 0.055, green: 0.059, blue: 0.070, alpha: 1.0)
            win.contentView = NSHostingView(
                rootView: PermissionsSheetView(enumerator: .shared, loginStatus: loginStatusModel)
            )
            self.window = win
        }

        WindowEnumerator.shared.refreshPermissionFlags()
        loginStatusModel.refresh()
        startPolling()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    public func windowWillClose(_ notification: Notification) {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            WindowEnumerator.shared.refreshPermissionFlags()
            self?.loginStatusModel.refresh()
        }
    }
}

private final class LoginItemStatusModel: ObservableObject {
    @Published var status: SMAppService.Status = SMAppService.mainApp.status

    func refresh() {
        let current = SMAppService.mainApp.status
        if current != status {
            status = current
        }
    }

    func enableOrApprove() {
        if SMAppService.mainApp.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
            return
        }
        do {
            try SMAppService.mainApp.register()
        } catch {
            print("[Glance] Launch at login error: \(error)")
        }
        refresh()
        if status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }
}

private struct PermissionsSheetView: View {
    @ObservedObject var enumerator: WindowEnumerator
    @ObservedObject var loginStatus: LoginItemStatusModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "macwindow.on.rectangle")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(WindowTheme.platinumIce)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Glance Permissions")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("Enable once for instant switching, Dock hover & startup background run")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(WindowTheme.labelSecondary)
                }
            }

            VStack(spacing: 10) {
                permissionRow(
                    title: "Accessibility",
                    subtitle: "Required to switch, raise, close & Dock-hover windows",
                    granted: enumerator.hasAccessibilityPermission,
                    buttonTitle: enumerator.hasAccessibilityPermission ? "Granted" : "Open Accessibility",
                    action: {
                        enumerator.requestPermissions(accessibilityOnly: true)
                    }
                )

                permissionRow(
                    title: "Screen Recording",
                    subtitle: "Required for live thumbnail previews inside cards",
                    granted: enumerator.hasScreenRecordingPermission,
                    buttonTitle: enumerator.hasScreenRecordingPermission ? "Granted" : "Open Screen Recording",
                    action: {
                        _ = CGRequestScreenCaptureAccess()
                        enumerator.openPrivacyPane(screenRecording: true)
                    }
                )

                permissionRow(
                    title: "Run in Background (Launch at Login)",
                    subtitle: "Starts Glance automatically when you turn on your Mac",
                    granted: loginStatus.status == .enabled,
                    buttonTitle: loginStatus.status == .enabled
                        ? "Enabled"
                        : (loginStatus.status == .requiresApproval ? "Approve in Settings" : "Enable"),
                    action: {
                        loginStatus.enableOrApprove()
                    }
                )
            }

            HStack {
                Text("Screen Recording requires a quick relaunch after toggling ON.")
                    .font(.system(size: 10.5, design: .rounded))
                    .foregroundStyle(WindowTheme.labelMuted)
                Spacer()
                Button("Relaunch") {
                    enumerator.relaunchApplication()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(20)
        .frame(width: 460, height: 308)
        .background(NativeVibrancyBackground(material: .hudWindow, cornerRadius: 12, tintOpacity: 0.72))
    }

    @ViewBuilder
    private func permissionRow(
        title: String,
        subtitle: String,
        granted: Bool,
        buttonTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(granted ? WindowTheme.anodizedSage : WindowTheme.champagneGold)
                .frame(width: 9, height: 9)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.system(size: 10.5, design: .rounded))
                    .foregroundStyle(WindowTheme.labelSecondary)
                    .lineLimit(1)
            }

            Spacer()

            Button(buttonTitle, action: action)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(granted)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(WindowTheme.cardSurface))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(WindowTheme.cardBorderSubtle, lineWidth: 1))
    }
}
