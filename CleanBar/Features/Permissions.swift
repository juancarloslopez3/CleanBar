import AppKit
import ApplicationServices
import Observation
import Security

/// A permission CleanBar asks for, allowed in System Settings → Privacy & Security.
nonisolated enum Permission {
    case accessibility
    case screenRecording

    var title: String {
        switch self {
        case .accessibility: String(localized: "Accessibility")
        case .screenRecording: String(localized: "Screen Recording")
        }
    }

    var isGranted: Bool {
        switch self {
        case .accessibility: Permissions.accessibilityGranted
        case .screenRecording: Permissions.screenRecordingGranted
        }
    }

    /// Its list in System Settings → Privacy & Security.
    var settingsAnchor: String {
        switch self {
        case .accessibility: "Privacy_Accessibility"
        case .screenRecording: "Privacy_ScreenCapture"
        }
    }
}

enum Permissions {
    /// Needed to read where menu bar items are and to move them (by posting ⌘-drag events).
    nonisolated static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    /// Needed to take pictures of menu bar items for the layout editor and the floating bar. Asking takes about 15 ms
    /// (macOS 27.0.1), so where it's asked again and again, it's asked off the main thread.
    nonisolated static var screenRecordingGranted: Bool { CGPreflightScreenCaptureAccess() }

    /// Opens the permission's list in System Settings, with CleanBar's icon in a panel below it to drag into the list
    /// (`PermissionGuide`). Dropping it there adds CleanBar and turns it on. macOS's own prompt isn't asked for: it would
    /// cover System Settings, and the CleanBar it adds to the list is turned off.
    static func request(_ permission: Permission) {
        openPrivacySettings(permission.settingsAnchor)
        PermissionGuide.shared.show(for: permission)
    }

    static func openPrivacySettings(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// System Settings → Menu Bar, where items can be turned off ("Allow in the Menu Bar").
    static func openMenuBarSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Another menu bar organizer that would fight CleanBar over item positions, if one is running.
    static var conflictingAppName: String? {
        let bundleIDPrefixes = [
            "com.surteesstudios.Bartender",
            "com.jordanbaird.Ice",
            "com.dwarvesv.minimalbar",
            "com.mortennn.Dozer",
        ]
        let app = NSWorkspace.shared.runningApplications.first { app in
            bundleIDPrefixes.contains { app.bundleIdentifier?.hasPrefix($0) == true }
        }
        return app?.localizedName
    }

    // MARK: Old entries

    // macOS remembers a permission together with the app's code signature. An ad hoc–signed build ("Sign to Run
    // Locally") has a new signature every time, so after an update System Settings still shows the old build's
    // switch as on, but it doesn't apply to the new one and turning it on again does nothing. Removing the entry
    // (`tccutil reset`, which needs no admin rights for the app's own bundle ID) lets "Allow…" add a fresh one.

    private enum Key {
        static let signature = "permissionsSignature"
        static let resetsOnLaunch = "resetsPermissionsOnLaunch"
    }

    /// Called at launch: removes the entries of missing permissions when this is a new build, or when "Reset
    /// Permissions" asked for it. It waits for the restart because Screen Recording only reads as allowed then, and
    /// an entry that just needed the restart would be lost.
    static func removeOldEntries() {
        let defaults = UserDefaults.standard
        let signature = designatedRequirement
        let isNewBuild = signature != defaults.string(forKey: Key.signature)
        let wasAsked = defaults.bool(forKey: Key.resetsOnLaunch)
        defaults.set(signature, forKey: Key.signature)
        defaults.removeObject(forKey: Key.resetsOnLaunch)
        guard isNewBuild || wasAsked else { return }
        if !accessibilityGranted { reset("Accessibility") }
        if !screenRecordingGranted { reset("ScreenCapture") }
    }

    /// Restarts CleanBar, which then removes the entries of the permissions still missing, so they can be allowed
    /// again.
    static func resetAndRelaunch() {
        UserDefaults.standard.set(true, forKey: Key.resetsOnLaunch)
        NSApp.relaunch()
    }

    private static func reset(_ service: String) {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        task.arguments = ["reset", service, bundleID]
        try? task.run()
        task.waitUntilExit()
    }

    /// What macOS checks a permission against. For an ad hoc–signed build it's the build's hash.
    private static var designatedRequirement: String? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var requirement: SecRequirement?
        var text: CFString?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess, let requirement,
              SecRequirementCopyString(requirement, [], &text) == errSecSuccess
        else { return nil }
        return text as String?
    }
}

/// The permissions CleanBar has, and the menu bar organizer that would fight it, kept current while CleanBar's settings
/// are open: the sidebar's badge and the Permissions pane show them.
@Observable
final class PermissionStatus {
    private(set) var accessibility = Permissions.accessibilityGranted
    private(set) var screenRecording = Permissions.screenRecordingGranted
    private(set) var conflictingAppName = Permissions.conflictingAppName

    /// How many of the permissions CleanBar asks for are missing.
    var missingCount: Int {
        [accessibility, screenRecording].count(where: { !$0 })
    }

    /// Asks again every second, until the task it runs in is cancelled. The permissions are asked off the main thread,
    /// which asking about Screen Recording would hold up for a moment each time.
    func keepCurrent() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            let (accessibility, screenRecording) = await Task.detached {
                (Permissions.accessibilityGranted, Permissions.screenRecordingGranted)
            }.value
            let conflictingAppName = Permissions.conflictingAppName
            // Only what changed, so the views don't update for nothing.
            if accessibility != self.accessibility { self.accessibility = accessibility }
            if screenRecording != self.screenRecording { self.screenRecording = screenRecording }
            if conflictingAppName != self.conflictingAppName { self.conflictingAppName = conflictingAppName }
        }
    }
}
