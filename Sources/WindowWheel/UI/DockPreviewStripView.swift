import SwiftUI
import AppKit

/// Compact Windows-taskbar-style floating preview strip anchored directly above a hovered macOS Dock icon
public struct DockPreviewStripView: View {
    @ObservedObject public var dockState: DockStripState
    @ObservedObject public var enumerator: WindowEnumerator
    public var onSelect: (WindowCardItem) -> Void
    public var onCloseWindow: (WindowCardItem) -> Void

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Compact floating glass label pill (transparent surrounding area)
            HStack(spacing: 7) {
                if let icon = dockState.appIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 15, height: 15)
                }
                Text(dockState.appName)
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Text("· \(dockState.windows.count) window\(dockState.windows.count == 1 ? "" : "s")")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(WindowTheme.labelSecondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                ZStack {
                    NativeVibrancyBackground(material: .hudWindow, cornerRadius: 10, tintOpacity: 0.72)
                    WindowTheme.hudBackground.opacity(0.74)
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.white.opacity(0.16), lineWidth: 0.9))
            .shadow(color: Color.black.opacity(0.45), radius: 10, x: 0, y: 4)

            // Independent floating preview cards directly over the transparent screen
            HStack(spacing: 10) {
                ForEach(dockState.windows.prefix(5)) { win in
                    DockMiniCard(
                        item: win,
                        thumbnail: enumerator.thumbnails[win.cgWindowID],
                        onSelect: { onSelect(win) },
                        onClose: { onCloseWindow(win) }
                    )
                }
            }
        }
        .padding(12)
        .offset(y: dockState.isPresented ? 0 : 8)
        .scaleEffect(dockState.isPresented ? 1.0 : 0.965)
        .opacity(dockState.isPresented ? 1.0 : 0.0)
        .animation(.spring(response: 0.24, dampingFraction: 0.84), value: dockState.isPresented)
    }
}

struct DockMiniCard: View {
    let item: WindowCardItem
    let thumbnail: NSImage?
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovered: Bool = false

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 5) {
                Text(item.title)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if isHovered {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Color(white: 0.85))
                            .frame(width: 16, height: 16)
                            .background(Color.white.opacity(0.14))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
            }

            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(WindowTheme.thumbWell)

                if let thumb = thumbnail {
                    Image(nsImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .transition(.opacity)
                } else if let icon = item.appIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 34, height: 34)
                }
            }
            .frame(width: 196, height: 112)
        }
        .padding(8)
        .frame(width: 212)
        .background(
            ZStack {
                NativeVibrancyBackground(material: .hudWindow, cornerRadius: 12, tintOpacity: 0.72)
                (isHovered ? Color(red: 0.08, green: 0.11, blue: 0.17) : WindowTheme.hudBackground).opacity(isHovered ? 0.92 : 0.80)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(
                    isHovered ? Color(red: 0.36, green: 0.64, blue: 1.0) : Color.black.opacity(0.45),
                    lineWidth: isHovered ? 2.5 : 1.0
                )
        )
        .shadow(
            color: isHovered ? Color(red: 0.30, green: 0.56, blue: 0.98).opacity(0.55) : Color.black.opacity(0.46),
            radius: isHovered ? 15 : 12,
            x: 0,
            y: isHovered ? 4 : 6
        )
        .scaleEffect(isHovered ? 1.03 : 1.0)
        .animation(.spring(response: 0.2, dampingFraction: 0.82), value: isHovered)
        .animation(.easeOut(duration: 0.16), value: thumbnail != nil)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovered = $0 }
    }
}
