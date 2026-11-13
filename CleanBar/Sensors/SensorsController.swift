import AppKit

/// The Sensors setting: while it's on, the Mac's temperature is in the menu bar, or a symbol in its place, its sensors are read
/// every few seconds and their history kept, and clicking it lists them, with the fans. While it's off, none of that runs,
/// and macOS has the fans.
final class SensorsController: NSObject {
    let monitor = SensorMonitor()
    let fans: FanController
    /// Opens a pane of CleanBar's settings.
    var showSettings: ((SettingsTab) -> Void)?
    /// Whether the Sensors pane of the settings is showing the readings.
    var isPaneShowing = false {
        didSet { updatePace() }
    }

    /// Keeps the temperature out of the menu bar, while it's among the hidden icons and they aren't showing. It's still read,
    /// for the floating bar, the fans and the history.
    var keepsItemOut = false {
        didSet {
            if keepsItemOut != oldValue {
                updateItemVisibility()
            }
        }
    }

    private let settings: AppSettings
    /// Made the first time the setting is on.
    private var item: SensorItem?
    private lazy var panel = makePanel()

    init(settings: AppSettings) {
        self.settings = settings
        fans = FanController(settings: settings)
        super.init()
    }

    func start() {
        monitor.onRead = { [weak self] in
            guard let self else { return }
            self.updateItem()
            self.fans.readingsChanged(fans: self.monitor.fans, temperatures: self.monitor.temperatures)
        }
        fans.onChange = { [weak self] in
            self?.updatePace()
            self?.monitor.readNow()
        }
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(willTerminate), name: NSApplication.willTerminateNotification, object: nil)
        settingsChanged()
    }

    func settingsChanged() {
        if settings.showsSensors, !monitor.isRunning {
            fans.start()
            monitor.start()
            let item = self.item ?? makeItem()
            self.item = item
        } else if !settings.showsSensors, monitor.isRunning {
            monitor.stop()
            panel.close()
            fans.stop()
        }
        updateItemVisibility()
        updatePace()
        updateItem()
    }

    /// As seldom as what's showing the readings or acting on them allows, since that's what most of the CPU time goes to.
    private func updatePace() {
        if panel.isOpen {
            monitor.pace = .often
        } else if settings.menuBarSensor != TemperatureSensor.noneID || fans.followsRules || isPaneShowing {
            monitor.pace = .regular
        } else {
            monitor.pace = .seldom
        }
    }

    /// The temperature the menu bar shows, or nil when it shows the symbol.
    private var menuBarText: String? {
        guard settings.menuBarSensor != TemperatureSensor.noneID else { return nil }
        let temperature = monitor.temperatures[settings.menuBarSensor]
            ?? monitor.temperatures[TemperatureSensor.cpuAverageID]
            ?? monitor.sensors.lazy.compactMap { self.monitor.temperatures[$0.id] }.first
        return temperature.map { TemperatureText.string($0) } ?? "--°"
    }

    private func updateItemVisibility() {
        item?.isVisible = settings.showsSensors && !keepsItemOut
    }

    /// The temperature as the menu bar would show it right now, for the floating bar.
    var itemPicture: ItemPicture {
        let image = SensorItem.image(text: menuBarText, color: settings.sensorIconColor, size: settings.sensorIconSize)
        return settings.sensorIconColor == nil
            ? ItemPicture(glyph: image, color: nil, size: image.size)
            : ItemPicture(glyph: nil, color: image, size: image.size)
    }

    /// Opens the temperature from the floating bar, the way it was clicked there. It stays out of the menu bar, so the list
    /// opens below where the floating bar was, and a right click opens the menu at the pointer.
    func open(_ click: ItemClick, below anchor: NSRect?, on screen: NSScreen?) {
        if click.isRightClick || click.modifiers.contains(.control) {
            makeContextMenu().popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        } else {
            panel.show(below: anchor, on: screen)
            updatePace()
        }
    }

    private func updateItem() {
        guard settings.showsSensors else { return }
        item?.show(menuBarText, color: settings.sensorIconColor, size: settings.sensorIconSize)
    }

    private func makeItem() -> SensorItem {
        let item = SensorItem()
        item.onClick = { [weak self] event in self?.itemClicked(event: event) }
        return item
    }

    private func makePanel() -> SensorPanel {
        let panel = SensorPanel(model: SensorPanelModel(monitor: monitor, fans: fans, settings: settings))
        panel.ignoresClick = { [weak self] location in
            guard let area = self?.item?.clickArea else { return false }
            return NSMouseInRect(location, area, false)
        }
        panel.onClose = { [weak self] in
            self?.updatePace()
            self?.item?.isHighlighted = false
        }
        panel.onEditProfiles = { [weak self] in self?.showSettings?(.sensors) }
        return panel
    }

    private func itemClicked(event: NSEvent?) {
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            panel.close()
            item?.showMenu(makeContextMenu())
        } else if panel.isOpen {
            panel.close()
        } else {
            item?.isHighlighted = true
            panel.show(below: item?.frameOnScreen, on: item?.screen)
            updatePace()
        }
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        let settings = menu.addItem(withTitle: String(localized: "Sensor Settings"), action: #selector(openSettings), keyEquivalent: "")
        settings.target = self
        settings.image = NSImage(systemSymbolName: SettingsTab.sensors.symbol, accessibilityDescription: nil)
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: String(localized: "Quit CleanBar"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        return menu
    }

    @objc private func openSettings() {
        showSettings?(.sensors)
    }

    // MARK: The Mac sleeping and CleanBar quitting

    @objc private func willSleep() {
        monitor.history.save()
    }

    /// Fans go back to macOS during sleep, and this notices right away.
    @objc private func didWake() {
        monitor.readNow()
    }

    @objc private func willTerminate() {
        monitor.history.save()
    }
}
