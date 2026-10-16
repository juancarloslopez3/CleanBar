import AppKit

/// macOS's own menu bar icons that its allowlist names one by one. Raw values are macOS's `MBSystemItemIdentifier`
/// values (battery, bluetooth, clock, displays, keyboard, volume, wifi, screenMirroring, primaryBentoBox); `identifier`
/// is the icon's Accessibility identifier. macOS's other icons (Focus, Now Playing…) have no value of their own.
nonisolated enum SystemMenuItem: Int, CaseIterable, Sendable {
    case battery, bluetooth, clock, display, keyboardBrightness, sound, wifi, screenMirroring, controlCenter

    var identifier: String {
        switch self {
        case .battery: "com.apple.menuextra.battery"
        case .bluetooth: "com.apple.menuextra.bluetooth"
        case .clock: "com.apple.menuextra.clock"
        case .display: "com.apple.menuextra.display"
        case .keyboardBrightness: "com.apple.menuextra.keyboard-brightness"
        case .sound: "com.apple.menuextra.sound"
        case .wifi: "com.apple.menuextra.wifi"
        case .screenMirroring: "com.apple.menuextra.screen-mirroring"
        case .controlCenter: "com.apple.menuextra.controlcenter"
        }
    }

    init?(identifier: String) {
        guard let item = Self.allCases.first(where: { $0.identifier == identifier }) else { return nil }
        self = item
    }

    /// The clock always stays: while icons are hidden, CleanBar opens Notification Center through it.
    var canBeHidden: Bool { self != .clock }
}

/// Hides menu bar icons with the menu bar allowlist built into macOS 27: other apps' icons app by app, and macOS's own
/// icons one by one.
///
/// macOS 27 can limit the menu bar to a list of apps and system items. It's meant for exam apps ("assessment mode"), and
/// its API is in the private MenuBarClientCore framework; Bartender 7 uses it the same way. While an assertion is
/// active, macOS only draws the icons of what's listed. The others leave the menu bar completely: no gap, no « button.
/// Invalidating the assertion, or quitting CleanBar, brings them back.
///
/// What CleanBar relies on, as observed on macOS 27.0.1:
/// - The list holds bundle identifiers. macOS only recognizes an icon's app when the app runs from /Applications,
///   /Library (iStat Menus runs from /Library/Application Support) or the system. Icons of apps running from anywhere
///   else (Xcode's build folder, ~/Applications, /Users/Shared, a temporary folder) are hidden whatever the list says,
///   CleanBar's own included. How the app was started doesn't matter: a launchd agent is no different.
/// - macOS's own icons are listed as `SystemMenuItem`s. One left out is hidden and drops out of the Accessibility tree
///   (seen with keyboard brightness, Wi-Fi, Bluetooth and Control Center). One listed is only allowed, not forced: one
///   the user turned off stays off.
/// - Activating an assertion takes over from the previous one straight away, so the list can change without the hidden
///   icons flashing.
/// - Notification Center doesn't open while an assertion is active, neither from the clock nor with the Show
///   Notification Center shortcut. Control Center does. MenuBarAgent tells Control Center and Notification Center
///   whether anything limits the menu bar, and they ignore the clock and the shortcut while something does, whatever
///   the list (any process's assertion counts). Pressed once they've been told the assertion is gone, the clock opens
///   Notification Center, and it stays open when an assertion is activated again right after the press.
///   `RestrictionMonitor` hears the same news, 10–30 ms after `lift()`.
/// - After `lift()`, MenuBarAgent brings the hidden icons back and only takes the next list once it has brought them all
///   back (25–40 ms later), as they start sliding in. A list activated by then takes them out again 5–7 ms later, before
///   they show much, unless MenuBarAgent is also busy with a click in the menu bar (see `ClockClickTap`).
final class IconHider {
    private var assertion: AssessmentModeAssertion?
    private(set) var allowedBundleIDs: Set<String>?
    private(set) var allowedSystemItems: Set<SystemMenuItem>?
    /// Whether macOS limits the menu bar right now, as Control Center and Notification Center hear it.
    let restrictions = RestrictionMonitor()

    var isActive: Bool { assertion != nil }

    /// False when this macOS doesn't have the private API (before macOS 27, or if a later update removes it).
    static let isAvailable: Bool = {
        dlopen("/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore", RTLD_NOW) != nil
            && NSClassFromString("MBAssessmentModeAssertion") != nil
            && (NSClassFromString("MBAssessmentModeConfiguration") as? NSObject.Type)?
                .instancesRespond(to: configurationInitializer) == true
    }()

    private static let configurationInitializer = NSSelectorFromString("initWithAllowedSystemItems:allowedBundleIdentifiers:")

    /// Whether macOS can tell which app an icon belongs to, which only works for apps in /Applications, /Library or the
    /// system.
    nonisolated static func isRecognized(appPath: String?) -> Bool {
        guard let appPath else { return false }
        return ["/Applications/", "/Library/", "/System/"].contains { appPath.hasPrefix($0) }
    }

    /// CleanBar's own icon hides with the others unless CleanBar runs from /Applications.
    static var isCleanBarRecognized: Bool { isRecognized(appPath: Bundle.main.bundlePath) }

    /// A list made ready with `prepare`, not yet handed to macOS.
    struct PreparedList {
        fileprivate let assertion: AssessmentModeAssertion
        fileprivate let configuration: AnyObject
        let bundleIDs: Set<String>
        let systemItems: Set<SystemMenuItem>
    }

    /// Shows only the icons of `bundleIDs` and `systemItems`. Returns false if macOS refused.
    @discardableResult
    func allow(only bundleIDs: Set<String>, systemItems: Set<SystemMenuItem>) async -> Bool {
        guard let list = prepare(only: bundleIDs, systemItems: systemItems) else { return false }
        return await allow(list)
    }

    /// Makes a list ready without handing it to macOS yet, for when the icons have to hide again as soon as possible.
    func prepare(only bundleIDs: Set<String>, systemItems: Set<SystemMenuItem>) -> PreparedList? {
        guard Self.isAvailable, let configuration = Self.makeConfiguration(bundleIDs: bundleIDs, systemItems: systemItems),
              let newAssertion = (NSClassFromString("MBAssessmentModeAssertion") as? NSObject.Type)?.init()
        else { return nil }
        return PreparedList(
            assertion: unsafeBitCast(newAssertion, to: AssessmentModeAssertion.self),
            configuration: configuration,
            bundleIDs: bundleIDs,
            systemItems: systemItems
        )
    }

    /// Shows only the icons a prepared list allows. Returns false if macOS refused.
    @discardableResult
    func allow(_ list: PreparedList) async -> Bool {
        let next = list.assertion
        let error: NSError? = await withCheckedContinuation { continuation in
            next.activate(with: list.configuration) { error in continuation.resume(returning: error) }
        }
        if let error {
            NSLog("CleanBar: macOS refused to hide menu bar icons: %@", error)
            next.invalidate()
            return false
        }
        // The new assertion is already in charge, so dropping the old one doesn't show anything in between.
        assertion?.invalidate()
        assertion = next
        allowedBundleIDs = list.bundleIDs
        allowedSystemItems = list.systemItems
        // Listening from now on, so it's ready long before the clock is clicked.
        restrictions.start()
        return true
    }

    /// Brings every hidden icon back.
    func lift() {
        assertion?.invalidate()
        assertion = nil
        allowedBundleIDs = nil
        allowedSystemItems = nil
    }

    private static func makeConfiguration(bundleIDs: Set<String>, systemItems: Set<SystemMenuItem>) -> AnyObject? {
        guard let configurationClass = NSClassFromString("MBAssessmentModeConfiguration") as? NSObject.Type,
              // alloc's reference is handed to the initializer, which consumes it and returns its own.
              let allocated = configurationClass.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue()
        else { return nil }
        let items = systemItems.map { NSNumber(value: $0.rawValue) }
        return allocated.perform(configurationInitializer, with: items as NSArray, with: Array(bundleIDs) as NSArray)?
            .takeRetainedValue()
    }
}

/// The methods of the private `MBAssessmentModeAssertion` class that CleanBar calls. Its methods are safe to call from
/// any thread: they only message MenuBarAgent.
@objc private protocol AssessmentModeAssertion: Sendable {
    @objc(activateWithConfiguration:completionHandler:)
    func activate(with configuration: AnyObject, completionHandler: @escaping @Sendable (NSError?) -> Void)
    func invalidate()
}

/// Hears from MenuBarAgent whether anything limits the menu bar to a list, the way Control Center and Notification Center
/// do. It connects to MenuBarAgent's visibility restriction service the way MenuBarClientCore does, through the private
/// BoardServices framework, but only listens: MenuBarAgent sends every connection the current state (1 while some
/// assertion is active, 0 once none is) when it connects and whenever it changes.
///
/// Seen on macOS 27.0.1: the news comes 10–30 ms after `IconHider.lift()`. Control Center hears it at about the same
/// time, and a clock press right after it opens Notification Center.
nonisolated final class RestrictionMonitor: NSObject, @unchecked Sendable {
    private static let machName = "com.apple.MenuBarAgent.systemservices"
    private static let service = "com.apple.MenuBarAgent.visibility-restriction"

    /// Everything below is only used on this queue, which is also where BoardServices calls in.
    private let queue = DispatchQueue(label: "com.cleanbar.CleanBar.restrictions", qos: .userInteractive)
    private var connection: ServiceConnection?
    /// Nil until MenuBarAgent has said.
    private var isRestricted: Bool?
    private var waiters: [UUID: CheckedContinuation<Bool?, Never>] = [:]

    func start() {
        queue.async { self.connect() }
    }

    /// Waits until MenuBarAgent says nothing limits the menu bar, as it does shortly after `IconHider.lift()`, and returns
    /// true. Returns false after `timeout`, and nil right away when this macOS can't tell.
    func waitUntilLifted(timeout: TimeInterval) async -> Bool? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool?, Never>) in
            queue.async {
                self.connect()
                guard self.connection != nil else { return continuation.resume(returning: nil) }
                if self.isRestricted == false { return continuation.resume(returning: true) }
                let id = UUID()
                self.waiters[id] = continuation
                self.queue.asyncAfter(deadline: .now() + timeout) {
                    self.waiters.removeValue(forKey: id)?.resume(returning: false)
                }
            }
        }
    }

    /// MenuBarAgent's message, on `queue`.
    @objc(visibilityRestrictionsDidChange:)
    func visibilityRestrictionsDidChange(_ state: NSNumber) {
        isRestricted = state.boolValue
        guard !state.boolValue else { return }
        let lifted = waiters.values
        waiters.removeAll()
        lifted.forEach { $0.resume(returning: true) }
    }

    private func connect() {
        guard connection == nil,
              let endpointClass = NSClassFromString("BSServiceConnectionEndpoint"),
              let connectionClass = NSClassFromString("BSServiceConnection"),
              let interfaceClass = NSClassFromString("BSMutableServiceInterface"),
              let protocolClass = NSClassFromString("BSObjCProtocol"),
              let qualityClass = NSClassFromString("BSServiceQuality"),
              // MenuBarClientCore's, loaded with it by `IconHider.isAvailable`.
              let server = objc_getProtocol("MBVisibilityRestrictionXPCServer"),
              let client = objc_getProtocol("MBVisibilityRestrictionXPCClient"),
              let endpoint = unsafeBitCast(endpointClass as AnyObject, to: ServiceEndpointClass.self)
                .endpoint(machName: Self.machName, service: Self.service, instance: nil),
              let made = unsafeBitCast(connectionClass as AnyObject, to: ServiceConnectionClass.self).connection(endpoint: endpoint)
        else { return }
        let protocols = unsafeBitCast(protocolClass as AnyObject, to: ObjCProtocolClass.self)
        let interface = unsafeBitCast(interfaceClass as AnyObject, to: ServiceInterfaceClass.self).interface(identifier: Self.service)
        interface.setServer(protocols.protocolFor(server))
        interface.setClient(protocols.protocolFor(client))
        let quality = unsafeBitCast(qualityClass as AnyObject, to: ServiceQualityClass.self).userInteractive()
        let connection = unsafeBitCast(made, to: ServiceConnection.self)
        connection.configure { [self] configuration in
            configuration.setInterface(interface)
            configuration.setInterfaceTarget(self)
            configuration.setServiceQuality(quality)
            configuration.setTargetQueue(queue)
            // When MenuBarAgent restarts. The next wait connects again, and MenuBarAgent sends the state then.
            configuration.setInterruptionHandler { [weak self] _ in self?.disconnect() }
            configuration.setInvalidationHandler { [weak self] _ in self?.disconnect() }
        }
        connection.activate()
        self.connection = connection
    }

    /// On `queue`.
    private func disconnect() {
        connection?.invalidate()
        connection = nil
        isRestricted = nil
    }
}

/// The BoardServices calls `RestrictionMonitor` makes. The class methods are called on the classes themselves.
@objc private nonisolated protocol ServiceEndpointClass {
    @objc(endpointForMachName:service:instance:)
    func endpoint(machName: String, service: String, instance: String?) -> AnyObject?
}

@objc private nonisolated protocol ServiceConnectionClass {
    @objc(connectionWithEndpoint:)
    func connection(endpoint: AnyObject) -> AnyObject?
}

@objc private nonisolated protocol ServiceInterfaceClass {
    @objc(interfaceWithIdentifier:)
    func interface(identifier: String) -> ServiceInterface
}

@objc private nonisolated protocol ServiceInterface {
    @objc(setServer:) func setServer(_ server: AnyObject)
    @objc(setClient:) func setClient(_ client: AnyObject)
}

@objc private nonisolated protocol ObjCProtocolClass {
    @objc(protocolForProtocol:)
    func protocolFor(_ objcProtocol: Protocol) -> AnyObject
}

@objc private nonisolated protocol ServiceQualityClass {
    func userInteractive() -> AnyObject
}

@objc private nonisolated protocol ServiceConnection {
    @objc(configureConnection:)
    func configure(_ configurator: @escaping (ServiceConnectionConfiguration) -> Void)
    func activate()
    func invalidate()
}

@objc private nonisolated protocol ServiceConnectionConfiguration {
    @objc(setInterface:) func setInterface(_ interface: ServiceInterface)
    @objc(setInterfaceTarget:) func setInterfaceTarget(_ target: AnyObject)
    @objc(setServiceQuality:) func setServiceQuality(_ quality: AnyObject)
    @objc(setTargetQueue:) func setTargetQueue(_ queue: DispatchQueue)
    @objc(setInterruptionHandler:) func setInterruptionHandler(_ handler: @escaping (AnyObject) -> Void)
    @objc(setInvalidationHandler:) func setInvalidationHandler(_ handler: @escaping (AnyObject) -> Void)
}
