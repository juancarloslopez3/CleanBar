import SwiftUI

/// The Bartender-style editor: one row per section, filled with pictures of the real menu bar items.
struct LayoutView: View {
    let model: LayoutModel
    let router: SettingsRouter
    let settings: AppSettings

    var body: some View {
        Form {
            Section {
                PaneHeader(
                    tab: .layout,
                    description: "Drag icons between Shown and Hidden to choose which ones CleanBar hides. While this window is open, hidden icons are showing."
                )
            }
            notices
            if !Permissions.accessibilityGranted {
                Section {
                    Notice(
                        text: String(localized: "CleanBar needs the Accessibility permission to read and move menu bar items."),
                        buttonTitle: String(localized: "Open Permissions")
                    ) { router.tab = .permissions }
                }
            } else if let snapshot = model.snapshot {
                sections(snapshot)
            } else {
                Section {
                    ProgressView("Reading your menu bar…")
                        .frame(maxWidth: .infinity, minHeight: 120)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(SettingsTab.layout.title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await model.refresh() }
                } label: {
                    Label {
                        Text("Refresh")
                    } icon: {
                        SpinningSymbol(systemName: "arrow.clockwise", isSpinning: model.isWorking)
                    }
                }
                .help("Read the menu bar again")
                .disabled(model.isWorking)
            }
        }
        .task { await model.beginEditing() }
        .onDisappear { model.endEditing() }
    }

    @ViewBuilder
    private var notices: some View {
        let conflictingApp = Permissions.conflictingAppName
        if conflictingApp != nil || !IconHider.isAvailable || !IconHider.isCleanBarRecognized {
            Section {
                if let conflictingApp {
                    Notice(text: String(localized: "\(conflictingApp) is running. Quit it, or it and CleanBar will keep moving each other's items."))
                }
                if !IconHider.isAvailable {
                    Notice(text: String(localized: "This version of macOS doesn't let CleanBar hide icons. CleanBar needs macOS 27."))
                } else if !IconHider.isCleanBarRecognized {
                    Notice(text: String(localized: "CleanBar is running from \(Bundle.main.bundleURL.deletingLastPathComponent().path), so it isn't hiding anything: macOS only recognizes CleanBar's own icon in the Applications folder, and would hide it too. Move CleanBar there."))
                }
            }
        }
    }

    @ViewBuilder
    private func sections(_ snapshot: LayoutSnapshot) -> some View {
        Section {
            ItemShelf(section: .shown, items: snapshot.shown, unavailable: snapshot.unavailableItems(in: .shown), model: model)
        } header: {
            SectionHeader(title: LayoutSection.shown.title, subtitle: LayoutSection.shown.subtitle)
        }
        .disabled(model.isMoving)

        Section {
            ItemShelf(section: .hidden, items: snapshot.hidden, unavailable: snapshot.unavailableItems(in: .hidden), model: model)
        } header: {
            SectionHeader(title: LayoutSection.hidden.title, subtitle: LayoutSection.hidden.subtitle)
        } footer: {
            footnotes(snapshot)
        }
        .disabled(model.isMoving)

        if let message = model.message {
            Section {
                Notice(text: message, kind: .info)
            }
        }

        if !snapshot.turnedOff.isEmpty {
            TurnedOffSection(items: snapshot.turnedOff)
        }

        Section("Tips") {
            Tip(symbol: "square.stack.3d.up", text: "Apps hide as a whole, so an app's icons move together. macOS's own icons hide one by one, except the clock.")
            Tip(symbol: "hand.draw", text: "Drop an icon on another one to put it in front of it in the menu bar, or ⌘-drag icons there yourself.")
            Tip(symbol: "sparkles", text: "Drag “New icons appear here” to where icons of apps CleanBar hasn't seen before should go.")
            Tip(symbol: "eye.slash", text: toggleTip)
        }
    }

    /// What hides the hidden icons, and shows them again, while this window is open. Hovering doesn't: they're showing.
    private var toggleTip: LocalizedStringKey {
        if !settings.hidesIcon {
            return "Click the CleanBar icon or press your shortcut to see the menu bar without the hidden icons. They come back when you move an icon or click Refresh, and hide again when this window closes."
        }
        if settings.showHiddenIconsTrigger == .emptySpaceClick {
            return "Click an empty space in the menu bar or press your shortcut to see the menu bar without the hidden icons. They come back when you move an icon or click Refresh, and hide again when this window closes."
        }
        return "Press your shortcut to see the menu bar without the hidden icons. They come back when you move an icon or click Refresh, and hide again when this window closes."
    }

    @ViewBuilder
    private func footnotes(_ snapshot: LayoutSnapshot) -> some View {
        let unrecognized = snapshot.unrecognizedAppNames
        if !snapshot.notVisible.isEmpty || !unrecognized.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                if !snapshot.notVisible.isEmpty {
                    Text("Dimmed icons are behind Apple's « because the menu bar is full. Click Refresh to bring them out.")
                }
                if !unrecognized.isEmpty {
                    Text("\(unrecognized.formatted(.list(type: .and))) will also hide whenever CleanBar hides icons: macOS only tells apart apps in the Applications folder or in /Library.")
                }
            }
        }
    }
}

/// A section's name, with a line about it.
private struct SectionHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(subtitle)
                .font(.subheadline)
                .fontWeight(.regular)
                .foregroundStyle(.secondary)
        }
    }
}

/// One row of the menu bar: the icons shown or hidden, in menu bar order.
private struct ItemShelf: View {
    let section: LayoutSection
    let items: [MenuBarItem]
    /// Items that belong in this row but can't be moved right now (shown dimmed).
    let unavailable: [MenuBarItem]
    let model: LayoutModel
    @State private var isTargeted = false

    var body: some View {
        let hasMarker = model.newIconsSection == section
        let markerAnchorID = hasMarker ? model.newIconsAnchor(in: items + unavailable)?.id : nil
        ScrollView(.horizontal) {
            HStack(spacing: 0) {
                ForEach(items) { item in
                    if item.id == markerAnchorID {
                        NewIconsMarker(isPlaced: model.isNewIconsMarkerPlaced)
                    }
                    ItemTile(item: item, section: section, model: model)
                }
                ForEach(unavailable) { item in
                    if item.id == markerAnchorID {
                        NewIconsMarker(isPlaced: model.isNewIconsMarkerPlaced)
                    }
                    // Its picture from when it was last in the menu bar, if CleanBar has one.
                    MenuBarItemImage(item: item, picture: model.picture(for: item), isTrimmed: true)
                        .tileFrame()
                        .opacity(0.4)
                        .help("\(item.displayName) (not visible right now)")
                }
                if hasMarker, markerAnchorID == nil {
                    NewIconsMarker(isPlaced: model.isNewIconsMarkerPlaced)
                }
                if items.isEmpty, unavailable.isEmpty {
                    Text(section == .hidden ? "Drop icons here to hide them" : "Drop icons here")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 8)
                        .allowsHitTesting(false)
                }
            }
            .padding(.horizontal, 4)
            .frame(minHeight: 40)
            // Icons slide into their new places when the menu bar has been read again.
            .animation(.snappy, value: model.snapshot?.date)
            .modifier(ReadingShimmer(isActive: model.isRefreshing))
        }
        .scrollIndicators(.never)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.accentColor.opacity(isTargeted ? 0.12 : 0))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(isTargeted ? 1 : 0), lineWidth: 2)
        }
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first else { return false }
            model.requestMove(id, to: section, before: nil)
            return true
        } isTargeted: { isTargeted = $0 }
    }
}

private struct ItemTile: View {
    let item: MenuBarItem
    let section: LayoutSection
    let model: LayoutModel
    @State private var isTargeted = false
    @State private var isHovered = false

    var body: some View {
        tile
            .background {
                HoverHighlight(isOn: isHovered)
            }
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .help(item.displayName)
            .accessibilityLabel(item.displayName)
            .draggable(item.id) { tile }
            .overlay(alignment: .leading) {
                if isTargeted {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: 3)
                        .padding(.vertical, 4)
                        .offset(x: -1.5)
                }
            }
            .dropDestination(for: String.self) { ids, _ in
                guard let id = ids.first, id != item.id else { return false }
                model.requestMove(id, to: section, before: item.id)
                return true
            } isTargeted: { isTargeted = $0 }
    }

    private var tile: some View {
        icon.tileFrame()
    }

    @ViewBuilder
    private var icon: some View {
        if item.controlRole == .icon {
            Image(nsImage: model.iconImage)
                .renderingMode(.template)
        } else {
            MenuBarItemImage(item: item, picture: model.picture(for: item), isTrimmed: true)
        }
    }
}

/// The room every icon in a row gets, in the editor and the floating bar: the same for each whatever room its app
/// leaves around it in the menu bar, so icons are evenly spaced.
enum IconTile {
    /// On each side of an icon, so there's twice this between two icons.
    static let padding: CGFloat = 8
    /// In the editor. The floating bar is as tall as the menu bar.
    static let height: CGFloat = 26
}

private extension View {
    func tileFrame() -> some View {
        padding(.horizontal, IconTile.padding)
            .frame(height: IconTile.height)
    }
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

/// While the menu bar is read again, a row's icons dim and a light sweeps across them (unless Reduce Motion is on).
private struct ReadingShimmer: ViewModifier {
    let isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Seconds for the light to cross the row.
    private let sweep = 1.3
    private let bandWidth: CGFloat = 110

    func body(content: Content) -> some View {
        content.mask {
            ZStack(alignment: .leading) {
                Rectangle()
                    .opacity(isActive ? 0.35 : 1)
                if isActive, !reduceMotion {
                    TimelineView(.animation) { context in
                        GeometryReader { proxy in
                            let progress = context.date.timeIntervalSinceReferenceDate
                                .truncatingRemainder(dividingBy: sweep) / sweep
                            LinearGradient(colors: [.clear, .black, .clear], startPoint: .leading, endPoint: .trailing)
                                .frame(width: bandWidth)
                                .offset(x: -bandWidth + progress * (proxy.size.width + bandWidth))
                        }
                    }
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.3), value: isActive)
        }
    }
}

/// Stands in for icons of apps CleanBar hasn't seen before: they go where it is.
private struct NewIconsMarker: View {
    /// False until it's dropped somewhere: new icons then only go to its row, where macOS puts them.
    let isPlaced: Bool
    @State private var isHovered = false

    var body: some View {
        label
            .background {
                HoverHighlight(isOn: isHovered)
                    .padding(.horizontal, IconTile.padding)
            }
            .onHover { isHovered = $0 }
            .help(isPlaced
                ? "Icons of apps CleanBar hasn't seen before go here. CleanBar ⌘-drags them into place, so the pointer jumps there for a moment. Icons already in the menu bar stay where they are."
                : "Icons of apps CleanBar hasn't seen before go to this row, where macOS puts them. Drop this on an icon to have them go in front of it, or on a row's empty space to have them go at its end.")
            .draggable(LayoutModel.newIconsMarkerID) { label }
    }

    private var label: some View {
        Label("New icons appear here", systemImage: "sparkles")
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .frame(height: IconTile.height)
            .background {
                Capsule()
                    .strokeBorder(.tertiary, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            .contentShape(Capsule())
            // As far from its neighbors as icons are from each other.
            .padding(.horizontal, IconTile.padding)
    }
}

private struct TurnedOffSection: View {
    let items: [MenuBarItem]

    var body: some View {
        Section {
            ForEach(items) { item in
                Label {
                    Text(item.displayName)
                } icon: {
                    MenuBarItemImage(item: item, picture: nil, height: 22)
                }
            }
        } header: {
            SectionHeader(
                title: String(localized: "Turned Off"),
                subtitle: String(localized: "Not allowed in the menu bar, under System Settings → Menu Bar")
            )
        } footer: {
            HStack {
                Spacer()
                Button("Open Menu Bar Settings…", action: Permissions.openMenuBarSettings)
            }
        }
    }
}

/// A symbol that turns at a steady pace while `isSpinning`, then slows to a stop upright.
private struct SpinningSymbol: View {
    let systemName: String
    let isSpinning: Bool
    /// Seconds per turn.
    private let period = 0.5
    @State private var start: Date?
    @State private var restingAngle = 0.0

    var body: some View {
        TimelineView(.animation(paused: start == nil)) { context in
            Image(systemName: systemName)
                .rotationEffect(.degrees(start.map { angle(at: context.date, since: $0) } ?? restingAngle))
        }
        .onChange(of: isSpinning, initial: true) { _, isSpinning in
            if isSpinning {
                start = .now
            } else {
                stop()
            }
        }
    }

    private func angle(at date: Date, since start: Date) -> Double {
        date.timeIntervalSince(start) / period * 360
    }

    private func stop() {
        guard let start else { return }
        let angle = angle(at: .now, since: start)
        let upright = (angle / 360).rounded(.up) * 360
        self.start = nil
        restingAngle = angle
        // Slowing down evenly from full speed takes twice as long as the rest of the turn would at full speed.
        withAnimation(.timingCurve(1 / 3, 2 / 3, 2 / 3, 1, duration: 2 * (upright - angle) / 360 * period)) {
            restingAngle = upright
        }
    }
}

private struct Tip: View {
    let symbol: String
    let text: LocalizedStringKey

    var body: some View {
        Label {
            Text(text)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(.tint)
        }
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
