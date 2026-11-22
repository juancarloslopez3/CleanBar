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
            Tip(symbol: "hand.draw", text: "Drop an icon between two others, or at either end of a row, to put it there in the menu bar, or ⌘-drag icons there yourself.")
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

/// One row of the menu bar: the icons shown or hidden, in menu bar order. They wrap to more lines rather than scroll, so
/// both ends of the row can always be reached during a drag.
private struct ItemShelf: View {
    let section: LayoutSection
    let items: [MenuBarItem]
    /// Items that belong in this row but can't be moved right now (shown dimmed).
    let unavailable: [MenuBarItem]
    let model: LayoutModel
    @State private var isTargeted = false
    @State private var tileFrames: [String: CGRect] = [:]
    /// Where a dragged icon would go.
    @State private var gap: ShelfGap?

    private nonisolated static let coordinateSpace = "ItemShelf"

    var body: some View {
        let hasMarker = model.newIconsSection == section
        let markerAnchorID = hasMarker ? model.newIconsAnchor(in: items + unavailable)?.id : nil
        WrappingRow {
            ForEach(items) { item in
                if item.id == markerAnchorID {
                    NewIconsMarker(isPlaced: model.isNewIconsMarkerPlaced)
                }
                ItemTile(item: item, model: model)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.coordinateSpace)) } action: { frame in
                        tileFrames[item.id] = frame
                    }
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
        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
        // Icons slide into their new places when the menu bar has been read again.
        .animation(.snappy, value: model.snapshot?.date)
        .modifier(ReadingShimmer(isActive: model.isRefreshing))
        .overlay(alignment: .topLeading) {
            if let gap {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 3, height: gap.height)
                    .offset(x: gap.x - 1.5, y: gap.y)
                    .allowsHitTesting(false)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.accentColor.opacity(isTargeted ? 0.12 : 0))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(isTargeted ? 1 : 0), lineWidth: 2)
                .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .coordinateSpace(.named(Self.coordinateSpace))
        .onDrop(of: [.plainText], delegate: ShelfDropDelegate(
            section: section,
            items: items,
            frames: items.compactMap { tileFrames[$0.id] },
            model: model,
            gap: $gap,
            isTargeted: $isTargeted
        ))
    }
}

/// Where in a row a dragged icon would go: before the row's item at `index`, or after them all.
struct ShelfGap: Equatable {
    var index: Int
    /// The line to show there, in the row's coordinates.
    var x: CGFloat
    var y: CGFloat
    var height: CGFloat

    /// The gap nearest `point`, given the frames of the row's items in order, which may wrap to more lines: on the line
    /// nearest `point`, before the first item whose middle is past it. Gaps from `limit` on aren't available, and give the
    /// gap at `limit` instead. Nil in a row with no items.
    init?(at point: CGPoint, in frames: [CGRect], limit: Int) {
        guard let nearest = frames.min(by: { Self.verticalDistance($0, point.y) < Self.verticalDistance($1, point.y) }) else {
            return nil
        }
        let line = frames.indices.filter { abs(frames[$0].minY - nearest.minY) < 1 }
        let end = (line.last ?? frames.count - 1) + 1
        let wanted = line.first { frames[$0].midX > point.x } ?? end
        index = max(0, min(wanted, limit))
        let isAtLineEnd = wanted == end && index == wanted
        let frame = frames[isAtLineEnd || index == frames.count ? max(index - 1, 0) : index]
        x = isAtLineEnd || index == frames.count ? frame.maxX : frame.minX
        y = frame.minY + 4
        height = max(frame.height - 8, 0)
    }

    private static func verticalDistance(_ frame: CGRect, _ y: CGFloat) -> CGFloat {
        y < frame.minY ? frame.minY - y : y > frame.maxY ? y - frame.maxY : 0
    }
}

/// A row takes every drop in it, and works out which gap it's nearest, so there's nowhere in it to miss, at either end
/// included.
private struct ShelfDropDelegate: DropDelegate {
    let section: LayoutSection
    let items: [MenuBarItem]
    let frames: [CGRect]
    let model: LayoutModel
    @Binding var gap: ShelfGap?
    @Binding var isTargeted: Bool

    private func gap(for info: DropInfo) -> ShelfGap? {
        ShelfGap(at: info.location, in: frames, limit: items.endOfMovableItems)
    }

    func dropEntered(info: DropInfo) {
        isTargeted = true
        gap = gap(for: info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let new = gap(for: info)
        if new != gap {
            gap = new
        }
        return nil
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
        gap = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        let place = gap(for: info).map { RowPlace(gap: $0.index, in: items) } ?? .anywhere
        isTargeted = false
        gap = nil
        guard let provider = info.itemProviders(for: [.plainText]).first else { return false }
        let model = model
        let section = section
        _ = provider.loadTransferable(type: String.self) { result in
            guard let id = try? result.get() else { return }
            Task { @MainActor in
                model.requestMove(id, to: section, at: place)
            }
        }
        return true
    }
}

/// Lays its views out in lines, as many as it takes.
private struct WrappingRow: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let lines = lines(of: subviews, width: proposal.width ?? .infinity)
        return CGSize(
            width: lines.map(\.width).max() ?? 0,
            height: lines.map(\.height).reduce(0, +)
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in lines(of: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in line.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                let width = min(size.width, bounds.width)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (line.height - size.height) / 2),
                    proposal: ProposedViewSize(width: width, height: size.height)
                )
                x += width
            }
            y += line.height
        }
    }

    private struct Line {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func lines(of subviews: Subviews, width: CGFloat) -> [Line] {
        var lines: [Line] = []
        var line = Line()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !line.indices.isEmpty, line.width + size.width > width {
                lines.append(line)
                line = Line()
            }
            line.indices.append(index)
            line.width += min(size.width, width)
            line.height = max(line.height, size.height)
        }
        if !line.indices.isEmpty {
            lines.append(line)
        }
        return lines
    }
}

private struct ItemTile: View {
    let item: MenuBarItem
    let model: LayoutModel
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

private extension View {
    func tileFrame() -> some View {
        padding(.horizontal, IconTile.padding)
            .frame(height: IconTile.height)
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
                : "Icons of apps CleanBar hasn't seen before go to this row, where macOS puts them. Drop this between two icons, or at either end of a row, to have them go there.")
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
