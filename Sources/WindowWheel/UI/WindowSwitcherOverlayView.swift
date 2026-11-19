import SwiftUI
import AppKit

/// Searchable NSTextField embedded cleanly inside WindowSwitcherOverlayView
public struct SwitcherSearchTextField: NSViewRepresentable {
    @Binding public var text: String
    public var placeholder: String
    public weak var state: SwitcherState?
    public var onActivateSearch: () -> Void
    public var onSubmit: () -> Void
    public var onStep: (Int) -> Void
    public var onEscape: () -> Void

    public func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    public func makeNSView(context: Context) -> NSTextField {
        let tf = NSTextField()
        tf.delegate = context.coordinator
        tf.isBordered = false
        tf.drawsBackground = false
        tf.focusRingType = .none
        tf.font = NSFont.systemFont(ofSize: 13.5, weight: .medium)
        tf.textColor = .white
        tf.maximumNumberOfLines = 1
        tf.usesSingleLineMode = true
        tf.cell?.wraps = false
        tf.cell?.isScrollable = true
        tf.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [
                .foregroundColor: NSColor(white: 0.44, alpha: 1.0),
                .font: NSFont.systemFont(ofSize: 12.5, weight: .regular)
            ]
        )
        state?.searchTextField = tf
        return tf
    }

    public func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.parent = self
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    public final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SwitcherSearchTextField
        init(parent: SwitcherSearchTextField) { self.parent = parent }

        public func controlTextDidBeginEditing(_ obj: Notification) {
            parent.onActivateSearch()
        }

        public func controlTextDidChange(_ obj: Notification) {
            guard let tf = obj.object as? NSTextField else { return }
            parent.text = tf.stringValue
        }

        public func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.moveDown(_:)) { parent.onStep(1); return true }
            if commandSelector == #selector(NSResponder.moveUp(_:)) { parent.onStep(-1); return true }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) { parent.onSubmit(); return true }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) { parent.onEscape(); return true }
            return false
        }
    }
}

public struct WindowSwitcherOverlayView: View {
    public let controller: OverlayPanelController
    @ObservedObject public var state: SwitcherState
    @ObservedObject public var enumerator: WindowEnumerator
    @ObservedObject public var tabBridge: BrowserTabBridge
    @Namespace private var scopeNS

    public var body: some View {
        let windows = controller.filteredWindows()
        let tabs = controller.filteredTabs()

        VStack(spacing: 0) {
            topHeaderBar(windowCount: windows.count, tabCount: tabBridge.tabs.count)
            Rectangle().fill(WindowTheme.dividerStroke).frame(height: 1)

            if !enumerator.hasScreenRecordingPermission || !enumerator.hasAccessibilityPermission {
                permissionBanner
            }

            ScrollViewReader { scrollProxy in
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 14) {
                        if state.scope != .browserTabs {
                            windowGridSection(windows: windows)
                        }

                        if !tabs.isEmpty || state.scope == .browserTabs {
                            browserTabsSection(tabs: tabs)
                        }
                    }
                    .padding(18)
                }
                .onChange(of: state.selectedWindowIndex) { _, newIdx in
                    guard newIdx >= 0 && newIdx < windows.count else { return }
                    withAnimation(.snappy(duration: 0.16)) {
                        scrollProxy.scrollTo(windows[newIdx].id, anchor: .center)
                    }
                }
                .onChange(of: state.selectedTabIndex) { _, newIdx in
                    guard state.scope == .browserTabs, newIdx >= 0 && newIdx < tabs.count else { return }
                    withAnimation(.snappy(duration: 0.16)) {
                        scrollProxy.scrollTo(tabs[newIdx].id, anchor: .center)
                    }
                }
            }

            Rectangle().fill(WindowTheme.dividerStroke).frame(height: 1)
            bottomFooterBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            ZStack {
                NativeVibrancyBackground(material: .hudWindow, cornerRadius: 20, tintOpacity: 0.72)
                WindowTheme.hudBackground.opacity(0.68)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(WindowTheme.specularRimGradient, lineWidth: 1.15)
        )
        .shadow(color: Color.black.opacity(0.65), radius: 36, x: 0, y: 18)
        .padding(14)
        .scaleEffect(state.isPresented ? 1.0 : 0.968)
        .opacity(state.isPresented ? 1.0 : 0.0)
        .animation(.spring(response: 0.24, dampingFraction: 0.86), value: state.isPresented)
    }

    @ViewBuilder
    private func topHeaderBar(windowCount: Int, tabCount: Int) -> some View {
        HStack(spacing: 12) {
            // Scope Pills with Native Sliding Capsule
            HStack(spacing: 4) {
                ForEach(Array(SwitcherScope.allCases.enumerated()), id: \.element.id) { idx, sc in
                    let isSelected = (state.scope == sc)
                    let title: String = {
                        switch sc {
                        case .allWindows:  return "All Windows (\(enumerator.windows.count))"
                        case .currentApp:  return state.frontAppName.isEmpty ? "Current App" : state.frontAppName
                        case .browserTabs: return "Browser Tabs (\(tabCount))"
                        }
                    }()

                    Button(action: {
                        withAnimation(.snappy(duration: 0.2)) {
                            state.scope = sc
                            state.selectedWindowIndex = 0
                            state.selectedTabIndex = 0
                        }
                        if sc == .browserTabs {
                            BrowserTabBridge.shared.refreshTabsAsync(force: true)
                            controller.transitionToStickySearch(initialChar: nil)
                        }
                    }) {
                        HStack(spacing: 4) {
                            Text(title)
                                .font(.system(size: 11, weight: isSelected ? .semibold : .medium, design: .rounded))
                                .lineLimit(1)
                            Text("⌘\(idx + 1)")
                                .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                                .opacity(isSelected ? 0.72 : 0.40)
                        }
                        .foregroundStyle(isSelected ? WindowTheme.labelPrimary : Color(white: 0.62))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5.5)
                        .background {
                            if isSelected {
                                Capsule()
                                    .fill(Color.white.opacity(0.15))
                                    .overlay(Capsule().stroke(Color.white.opacity(0.30), lineWidth: 0.9))
                                    .matchedGeometryEffect(id: "activeScopePill", in: scopeNS)
                            } else {
                                Capsule().fill(Color.white.opacity(0.03))
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(KeyEquivalent(Character("\(idx + 1)")), modifiers: .command)
                }
            }

            // Compact Live Search Pill
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(WindowTheme.platinumIce.opacity(0.8))

                SwitcherSearchTextField(
                    text: $state.searchQuery,
                    placeholder: "Type to filter windows & tabs...",
                    state: state,
                    onActivateSearch: {
                        controller.onEnterStickySearch?()
                    },
                    onSubmit: {
                        controller.commitSelectionAndHide()
                    },
                    onStep: { delta in
                        controller.stepSelection(delta: delta)
                    },
                    onEscape: {
                        controller.onCommitCallback?()
                        controller.cancelAndHide()
                    }
                )
                .frame(maxWidth: .infinity)
                .frame(height: 22)
                .onChange(of: state.searchQuery) { _, _ in
                    state.selectedWindowIndex = 0
                    state.selectedTabIndex = 0
                }

                if !state.searchQuery.isEmpty {
                    Button(action: { state.searchQuery = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Color(white: 0.45))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 9).fill(WindowTheme.cardSurface))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.white.opacity(state.isStickyMode ? 0.25 : 0.10), lineWidth: 1))

            Button(action: {
                controller.onCommitCallback?()
                controller.cancelAndHide()
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(WindowTheme.labelSecondary)
                    .frame(width: 24, height: 24)
                    .background(Color.white.opacity(0.08))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .frame(height: 54)
    }

    @ViewBuilder
    private var permissionBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles.tv.fill")
                .font(.system(size: 13))
                .foregroundStyle(WindowTheme.champagneGold)

            Text(!enumerator.hasAccessibilityPermission
                 ? "Grant Accessibility for Glance to switch, close & hover-preview windows"
                 : "Toggle Glance ON in System Settings → Screen Recording, then click Relaunch")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(Color(white: 0.85))
                .lineLimit(1)

            Spacer()

            Button(action: {
                controller.onCommitCallback?()
                controller.dismissMainGrid(restorePreviousApp: false)
                enumerator.requestPermissions()
            }) {
                Text(!enumerator.hasAccessibilityPermission ? "Grant Access" : "Open Settings")
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.black)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(WindowTheme.platinumIce)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            if !enumerator.hasScreenRecordingPermission {
                Button(action: {
                    enumerator.captureThumbnailsAsync(for: enumerator.windows, maxThumbWidth: 260, forceProbe: true)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        if !enumerator.hasScreenRecordingPermission {
                            enumerator.relaunchApplication()
                        }
                    }
                }) {
                    Text("Relaunch")
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.14))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.04))
    }

    @ViewBuilder
    private func windowGridSection(windows: [WindowCardItem]) -> some View {
        if windows.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "macwindow")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(Color(white: 0.30))
                Text(state.scope == .currentApp ? "No open windows in \(state.frontAppName)" : "No matching windows")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(white: 0.52))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 60)
        } else {
            let cols = Array(repeating: GridItem(.flexible(), spacing: 12), count: min(4, max(1, windows.count)))
            LazyVGrid(columns: cols, spacing: 12) {
                ForEach(Array(windows.enumerated()), id: \.element.id) { idx, item in
                    WindowPreviewCard(
                        item: item,
                        thumbnail: enumerator.thumbnails[item.cgWindowID],
                        isSelected: idx == state.selectedWindowIndex,
                        isExpanded: state.expandedBrowserBundleID == item.bundleID,
                        canHoverSelect: { controller.hasMouseMovedSinceOpen() },
                        onHoverSelect: { state.selectedWindowIndex = idx },
                        onSelect: { controller.selectWindowCard(item) },
                        onClose: { WindowEnumerator.shared.closeWindow(item) },
                        onToggleTabs: {
                            BrowserTabBridge.shared.refreshTabsAsync(force: true)
                            controller.transitionToStickySearch(initialChar: nil)
                            withAnimation(.snappy(duration: 0.2)) {
                                state.expandedBrowserBundleID = (state.expandedBrowserBundleID == item.bundleID) ? nil : item.bundleID
                            }
                        },
                        onSnapLeft: {
                            controller.dismissMainGrid(restorePreviousApp: false)
                            WindowEnumerator.shared.snapWindow(item, mode: .leftHalf)
                        },
                        onSnapRight: {
                            controller.dismissMainGrid(restorePreviousApp: false)
                            WindowEnumerator.shared.snapWindow(item, mode: .rightHalf)
                        }
                    )
                    .id(item.id)
                }
            }
        }
    }

    @ViewBuilder
    private func browserTabsSection(tabs: [BrowserTabItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(state.scope == .browserTabs ? "OPEN BROWSER TABS" : "MATCHING BROWSER TABS")
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(WindowTheme.labelSecondary)
                Spacer()
                if tabBridge.isLoading {
                    ProgressView().scaleEffect(0.45)
                }
            }

            if tabs.isEmpty {
                Text("No matching Chrome, Safari, or Arc tabs found (or allow Browser Automation in System Settings).")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(WindowTheme.labelMuted)
                    .padding(.vertical, 12)
            } else {
                VStack(spacing: 4) {
                    ForEach(Array(tabs.enumerated()), id: \.element.id) { idx, tab in
                        let isSel = (state.scope == .browserTabs && idx == state.selectedTabIndex)
                        BrowserTabRow(
                            tab: tab,
                            isSelected: isSel,
                            onHoverSelect: {
                                if state.scope == .browserTabs && controller.hasMouseMovedSinceOpen() {
                                    state.selectedTabIndex = idx
                                }
                            },
                            onActivate: { controller.selectBrowserTab(tab) },
                            onClose: { tabBridge.closeTab(tab) }
                        )
                        .id(tab.id)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var bottomFooterBar: some View {
        HStack(spacing: 14) {
            footerHint(key: "⌥Tab", label: "Next Window")
            footerHint(key: "⌥~", label: "Same App")
            footerHint(key: "Type", label: "Search Windows & Tabs")
            footerHint(key: "Q / ⌘W", label: "Close")
            Spacer()
            Text(state.isStickyMode ? "Pinned Search · ⏎ to Switch · Esc to Close" : "Release ⌥ to Switch")
                .font(.system(size: 9.5, weight: .medium, design: .rounded))
                .foregroundStyle(WindowTheme.labelMuted)
        }
        .padding(.horizontal, 18)
        .frame(height: 32)
        .background(Color.black.opacity(0.42))
    }

    @ViewBuilder
    private func footerHint(key: String, label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(Color(white: 0.78))
                .padding(.horizontal, 4.5)
                .padding(.vertical, 1.5)
                .background(Color.white.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 3.5))
            Text(label)
                .font(.system(size: 9.5, weight: .medium, design: .rounded))
                .foregroundStyle(WindowTheme.labelSecondary)
        }
    }
}

struct WindowPreviewCard: View {
    let item: WindowCardItem
    let thumbnail: NSImage?
    let isSelected: Bool
    let isExpanded: Bool
    let canHoverSelect: () -> Bool
    let onHoverSelect: () -> Void
    let onSelect: () -> Void
    let onClose: () -> Void
    let onToggleTabs: () -> Void
    let onSnapLeft: () -> Void
    let onSnapRight: () -> Void

    @State private var isHovered: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let active = isSelected || isHovered
        VStack(spacing: 0) {
            // ── Header Bar (Icon + Title + Close Button) ──
            HStack(spacing: 7) {
                if let icon = item.appIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 18, height: 18)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(item.appName)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(WindowTheme.labelSecondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if active {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(Color(white: 0.85))
                            .frame(width: 18, height: 18)
                            .background(Color.white.opacity(0.12))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Close Window")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            // ── Live Window Thumbnail Well ──
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(WindowTheme.thumbWell)

                if let thumb = thumbnail {
                    Image(nsImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .opacity((item.isMinimized || item.isHidden) ? 0.45 : 1.0)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .transition(.opacity)
                }

                if thumbnail == nil || item.isMinimized || item.isHidden {
                    VStack(spacing: 6) {
                        if let icon = item.appIcon {
                            Image(nsImage: icon)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 40, height: 40)
                                .opacity(0.90)
                        }
                        if item.isMinimized || item.isHidden {
                            Text(item.isMinimized ? "MINIMIZED" : "HIDDEN")
                                .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                                .foregroundStyle(WindowTheme.champagneGold)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(WindowTheme.champagneGold.opacity(0.16))
                                .clipShape(Capsule())
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                // Bottom-right quick toolbar on hover / selection
                if active {
                    HStack(spacing: 4) {
                        if item.isBrowser {
                            Button(action: onToggleTabs) {
                                Text(isExpanded ? "Hide Tabs" : "Tabs")
                                    .font(.system(size: 8.5, weight: .bold, design: .rounded))
                                    .foregroundStyle(WindowTheme.platinumIce)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(Color.black.opacity(0.75))
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }

                        Button(action: onSnapLeft) {
                            Image(systemName: "rectangle.lefthalf.inset.filled")
                                .font(.system(size: 9))
                                .foregroundStyle(.white)
                                .frame(width: 20, height: 20)
                                .background(Color.black.opacity(0.72))
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                        }
                        .buttonStyle(.plain)

                        Button(action: onSnapRight) {
                            Image(systemName: "rectangle.righthalf.inset.filled")
                                .font(.system(size: 9))
                                .foregroundStyle(.white)
                                .frame(width: 20, height: 20)
                                .background(Color.black.opacity(0.72))
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(6)
                }
            }
            .frame(height: 126)
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(active ? WindowTheme.cardSelected : WindowTheme.cardSurface))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(
                    isSelected ? WindowTheme.platinumIce.opacity(0.82) : (isHovered ? Color.white.opacity(0.28) : WindowTheme.cardBorderSubtle),
                    lineWidth: isSelected ? 1.8 : 1.0
                )
        )
        .shadow(color: isSelected ? WindowTheme.steelSapphire.opacity(0.28) : .clear, radius: 10)
        .scaleEffect(reduceMotion ? 1.0 : (isSelected ? 1.015 : (isHovered ? 1.007 : 1.0)))
        .animation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.82), value: isSelected)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: isHovered)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: thumbnail != nil)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering in
            if !hovering {
                isHovered = false
            } else if canHoverSelect() {
                isHovered = true
                onHoverSelect()
            }
        }
    }
}

struct BrowserTabRow: View {
    let tab: BrowserTabItem
    let isSelected: Bool
    let onHoverSelect: () -> Void
    let onActivate: () -> Void
    let onClose: () -> Void

    @State private var isHovered: Bool = false

    var body: some View {
        let highlighted = isHovered || isSelected
        HStack(spacing: 10) {
            if let icon = tab.appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 22, height: 22)
            }

            Button(action: onActivate) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(tab.title)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        if tab.isActiveInWindow {
                            Text("ACTIVE")
                                .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                                .foregroundStyle(WindowTheme.anodizedSage)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(WindowTheme.anodizedSage.opacity(0.14))
                                .clipShape(Capsule())
                        }
                    }

                    Text("\(tab.browserName) · Win \(tab.windowIndex) · \(tab.domain)")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(Color(white: 0.48))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if highlighted {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color(white: 0.8))
                        .frame(width: 20, height: 20)
                        .background(Color.white.opacity(0.10))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
        .background(RoundedRectangle(cornerRadius: 9).fill(highlighted ? WindowTheme.cardSelected : WindowTheme.cardSurface))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(highlighted ? Color.white.opacity(0.25) : WindowTheme.cardBorderSubtle, lineWidth: 1))
        .onHover { hovering in
            isHovered = hovering
            if hovering { onHoverSelect() }
        }
    }
}
