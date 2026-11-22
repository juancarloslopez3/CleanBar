import AppKit
import SwiftUI

/// The room every icon in a row gets, in the editor and the floating bar: the same for each whatever room its app
/// leaves around it in the menu bar, so icons are evenly spaced.
enum IconTile {
    /// On each side of an icon, so there's twice this between two icons.
    static let padding: CGFloat = 8
    /// In the editor. The floating bar is as tall as the menu bar.
    static let height: CGFloat = 26
}

/// The shade the menu bar puts behind an item under the pointer, filling the item's tile, and darker while it's
/// pressed.
struct HoverHighlight: View {
    let isOn: Bool
    var isPressed = false

    var body: some View {
        Capsule()
            .fill(isPressed ? .secondary : .tertiary)
            .opacity(isOn || isPressed ? 1 : 0)
            .animation(.easeOut(duration: 0.12), value: isOn)
    }
}

/// A menu bar item the way the menu bar shows it: its picture, drawn in the window's text color, or else a symbol or
/// its app's icon.
struct MenuBarItemImage: View {
    let item: MenuBarItem
    let picture: ItemPicture?
    /// The height to draw it at. Pictures keep their size in the menu bar.
    var height: CGFloat?
    /// Leaves out the room the item has around its icon in the menu bar, which differs from app to app, so icons can be
    /// spaced evenly.
    var isTrimmed = false

    var body: some View {
        if let picture {
            let scale = height.map { $0 / picture.size.height } ?? 1
            let drawn = isTrimmed ? picture.drawnSpan : 0...picture.size.width
            ZStack {
                if let glyph = picture.glyph {
                    Image(nsImage: glyph)
                        .renderingMode(.template)
                        .resizable()
                        .interpolation(.high)
                }
                if let color = picture.color {
                    Image(nsImage: color)
                        .resizable()
                        .interpolation(.high)
                }
            }
            .frame(width: picture.size.width * scale, height: picture.size.height * scale)
            .offset(x: -drawn.lowerBound * scale)
            .frame(width: (drawn.upperBound - drawn.lowerBound) * scale, alignment: .leading)
            .clipped()
        } else {
            placeholder
        }
    }

    /// Without a picture: a symbol for macOS's own items, and the app's icon for others.
    @ViewBuilder
    private var placeholder: some View {
        let side = height ?? max(item.frame.height, 22)
        if let symbol = item.systemItem?.symbolName {
            Image(systemName: symbol)
                .font(.system(size: side * 0.46))
                .frame(width: isTrimmed ? nil : side * 1.2, height: side)
        } else {
            Image(nsImage: Self.appIcon(for: item))
                .resizable()
                .frame(width: side * 0.7, height: side * 0.7)
                .frame(width: isTrimmed ? side * 0.7 : side, height: side)
        }
    }

    private static func appIcon(for item: MenuBarItem) -> NSImage {
        NSRunningApplication(processIdentifier: item.pid)?.icon
            ?? NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)
            ?? NSImage()
    }
}

private extension SystemMenuItem {
    /// A symbol that looks like the item's icon, for when there's no picture of it.
    var symbolName: String? {
        switch self {
        case .battery: "battery.75percent"
        case .bluetooth: nil
        case .clock: "clock"
        case .display: "sun.max"
        case .keyboardBrightness: "light.max"
        case .sound: "speaker.wave.2.fill"
        case .wifi: "wifi"
        case .screenMirroring: "rectangle.on.rectangle"
        case .controlCenter: "switch.2"
        }
    }
}
