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
            HStack(spacing: 8) {
                if let icon = dockState.appIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 16, height: 16)
                }
                Text(dockState.appName)
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Text("· \(dockState.windows.count) window\(dockState.windows.count == 1 ? "" : "s")")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(WindowTheme.labelSecondary)
                Spacer()
            }
            .padding(.horizontal, 4)

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
        .background(
            ZStack {
                NativeVibrancyBackground(material: .hudWindow, cornerRadius: 16, tintOpacity: 0.72)
                WindowTheme.hudBackground.opacity(0.68)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(WindowTheme.specularRimGradient, lineWidth: 1.1))
        .shadow(color: Color.black.opacity(0.65), radius: 22, x: 0, y: 10)
        .padding(10)
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
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(isHovered ? WindowTheme.cardSelected : WindowTheme.cardSurface))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(isHovered ? WindowTheme.platinumIce.opacity(0.65) : WindowTheme.cardBorderSubtle, lineWidth: 1))
        .scaleEffect(isHovered ? 1.015 : 1.0)
        .animation(.spring(response: 0.2, dampingFraction: 0.82), value: isHovered)
        .animation(.easeOut(duration: 0.16), value: thumbnail != nil)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovered = $0 }
    }
}
