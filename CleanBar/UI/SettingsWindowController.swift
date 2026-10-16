import AppKit
import SwiftUI

nonisolated enum SettingsTab: Hashable, CaseIterable, Identifiable {
    case layout
    case general
    case permissions
    case about

    var id: Self { self }

    var title: String {
        switch self {
        case .layout: String(localized: "Menu Bar Layout")
        case .general: String(localized: "General")
        case .permissions: String(localized: "Permissions")
        case .about: String(localized: "About")
        }
    }

    /// The pane's icon: a white symbol on a square of `tint`, like the panes of System Settings.
    var symbol: String {
        switch self {
        case .layout: "menubar.rectangle"
        case .general: "gearshape.fill"
        case .permissions: "hand.raised.fill"
        case .about: "info.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .layout: .blue
        case .general: .gray
        case .permissions: .indigo
        case .about: .gray
        }
    }
}

@Observable
final class SettingsRouter {
    var tab: SettingsTab = .layout
}

final class SettingsWindowController: NSObject, NSWindowDelegate {
    private weak var manager: MenuBarManager?
    private let router = SettingsRouter()
    private var window: NSWindow?
    private weak var sidebar: NSSplitViewItem?
    private var sidebarObservations: [NSKeyValueObservation] = []

    init(manager: MenuBarManager) {
        self.manager = manager
        super.init()
        PermissionGuide.shared.onAllowed = { [weak self] in self?.comeBack() }
    }

    func show(tab: SettingsTab) {
        guard let manager else { return }
        router.tab = tab
        let window = self.window ?? makeWindow(manager: manager)
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// Brings the window back in front of System Settings once a permission was allowed there, if it's still open, so
    /// the next step shows. System Settings has to agree: plain `NSApp.activate()` can be turned down, activating from
    /// the app in front works.
    private func comeBack() {
        guard let window, window.isVisible else { return }
        if let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            NSRunningApplication.current.activate(from: front, options: [])
        }
        window.makeKeyAndOrderFront(nil)
    }

    /// Closes the window, which ends the layout editor's session.
    func close() {
        window?.close()
    }

    private func makeWindow(manager: MenuBarManager) -> NSWindow {
        let root = SettingsView(router: router, settings: manager.settings, layout: manager.layout, permissions: PermissionStatus())
        let controller = NSHostingController(rootView: root)
        // Each pane's title and buttons go in the window's toolbar, as in System Settings.
        controller.sceneBridgingOptions = [.title, .toolbars]
        // The window keeps the size it's given, and SwiftUI only sets how small it can get.
        controller.sizingOptions = [.minSize]
        // The sidebar runs up behind the title bar. The controller is set after the window is made: made with
        // `NSWindow(contentViewController:)`, the window keeps its own title instead of the pane's (seen on macOS 27).
        let window = SettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.title = "CleanBar"
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        // Setting the controller sized the window to its content.
        window.setContentSize(NSSize(width: 860, height: 640))
        window.center()
        window.delegate = self
        pinSidebar(in: controller.view)
        return window
    }

    /// Keeps the sidebar one width and always showing, like System Settings'. SwiftUI's sidebar can be dragged wider,
    /// narrower or shut, with no way to open it again, and SwiftUI doesn't apply `navigationSplitViewColumnWidth` in
    /// this window (seen on macOS 27), so it's set on the split view AppKit makes for it.
    private func pinSidebar(in view: NSView) {
        guard let splitView = view.firstSubview(ofType: NSSplitView.self),
              let splitController = splitView.delegate as? NSSplitViewController,
              let sidebar = splitController.splitViewItems.first(where: { $0.behavior == .sidebar })
        else { return }
        self.sidebar = sidebar
        keepSidebarPinned()
        // SwiftUI puts its own values back each time it updates the window, so they're set again whenever they change.
        sidebarObservations = [
            sidebar.observe(\.canCollapse) { @Sendable [weak self] _, _ in
                MainActor.assumeIsolated { self?.keepSidebarPinned() }
            },
            sidebar.observe(\.canCollapseFromWindowResize) { @Sendable [weak self] _, _ in
                MainActor.assumeIsolated { self?.keepSidebarPinned() }
            },
            sidebar.observe(\.minimumThickness) { @Sendable [weak self] _, _ in
                MainActor.assumeIsolated { self?.keepSidebarPinned() }
            },
            sidebar.observe(\.maximumThickness) { @Sendable [weak self] _, _ in
                MainActor.assumeIsolated { self?.keepSidebarPinned() }
            },
        ]
    }

    private func keepSidebarPinned() {
        guard let sidebar else { return }
        let width = SettingsView.sidebarWidth
        // Only what changed is set, as setting a value calls the observers again.
        if sidebar.canCollapse { sidebar.canCollapse = false }
        if sidebar.canCollapseFromWindowResize { sidebar.canCollapseFromWindowResize = false }
        if sidebar.minimumThickness != width { sidebar.minimumThickness = width }
        if sidebar.maximumThickness != width { sidebar.maximumThickness = width }
        if sidebar.isCollapsed { sidebar.isCollapsed = false }
    }

    func windowWillClose(_ notification: Notification) {
        manager?.layout.endEditing()
        // A fresh window next time, so the layout editor starts a new session when it appears.
        window = nil
        sidebarObservations = []
    }
}

/// The settings window. It always has a toolbar, so every pane has the same title bar: SwiftUI only gives the window
/// one on panes with toolbar buttons, and without it the title bar is shorter, so the window buttons and the pane's
/// title would jump when switching panes. The toolbar only has each pane's title and buttons, so right-clicking it
/// doesn't offer to show them as icons or text.
private final class SettingsWindow: NSWindow {
    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        toolbar = Self.emptyToolbar()
    }

    // SwiftUI gives the window a new toolbar whenever it switches to a pane with toolbar buttons, and takes it away on
    // the others.
    override var toolbar: NSToolbar? {
        get { super.toolbar }
        set {
            let toolbar = newValue ?? Self.emptyToolbar()
            toolbar.allowsDisplayModeCustomization = false
            super.toolbar = toolbar
        }
    }

    /// Stands in for SwiftUI's toolbar on panes without toolbar buttons. Icons only, like SwiftUI's: with room for
    /// labels, it would be taller.
    private static func emptyToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: "CleanBar.Empty")
        toolbar.displayMode = .iconOnly
        return toolbar
    }
}

private extension NSView {
    /// The first view of the type in this view's subviews, their subviews and so on.
    func firstSubview<View: NSView>(ofType type: View.Type) -> View? {
        for subview in subviews {
            if let match = subview as? View ?? subview.firstSubview(ofType: type) {
                return match
            }
        }
        return nil
    }
}

/// A sidebar with the panes, like System Settings.
struct SettingsView: View {
    let router: SettingsRouter
    let settings: AppSettings
    let layout: LayoutModel
    let permissions: PermissionStatus

    /// The sidebar is always this wide, like System Settings'. `SettingsWindowController` keeps it that way.
    static let sidebarWidth: CGFloat = 210

    var body: some View {
        // The sidebar can't be hidden: without a toggle to show it again, the other panes would be out of reach.
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(selection: selection) {
                ForEach(SettingsTab.allCases) { tab in
                    Label {
                        Text(tab.title)
                    } icon: {
                        SymbolBadge(symbol: tab.symbol, tint: tab.tint, size: 20)
                    }
                    .badge(tab == .permissions ? permissions.missingCount : 0)
                    .tag(tab)
                }
            }
            .navigationSplitViewColumnWidth(Self.sidebarWidth)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            switch router.tab {
            case .layout:
                LayoutView(model: layout, router: router, settings: settings)
            case .general:
                GeneralView(settings: settings)
            case .permissions:
                PermissionsView(permissions: permissions)
            case .about:
                AboutView()
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .task { await permissions.keepCurrent() }
    }

    /// There's always a pane selected.
    private var selection: Binding<SettingsTab?> {
        Binding {
            router.tab
        } set: { tab in
            if let tab {
                router.tab = tab
            }
        }
    }
}
