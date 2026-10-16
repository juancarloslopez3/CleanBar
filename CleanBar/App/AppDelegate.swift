import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Permissions.removeOldEntries()

        let manager = MenuBarManager(settings: .shared)
        menuBar = manager
        // Before any window shows. `AppSettings` applies changes from then on.
        NSApp.appearance = manager.settings.appearance.nsAppearance
        manager.start()

        let defaults = UserDefaults.standard
        let isFirstLaunch = !defaults.bool(forKey: "hasLaunchedBefore")
        defaults.set(true, forKey: "hasLaunchedBefore")
        let didSwitchLanguage = AppLanguage.didRestart()

        if !Permissions.accessibilityGranted || !Permissions.screenRecordingGranted {
            manager.showSettings(tab: .permissions)
        } else if isFirstLaunch {
            manager.showSettings(tab: .layout)
        } else if didSwitchLanguage {
            // Back where the language was picked.
            manager.showSettings(tab: .general)
        }
    }

    // Opening CleanBar again from Finder or Spotlight shows its settings, since it has no Dock icon.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        menuBar?.showSettings(tab: .layout)
        return false
    }
}

extension NSApplication {
    /// Quits CleanBar and opens it again once it's gone: opened while it's still running, it would only come to the
    /// front.
    func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = [
            "-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.1; done; /usr/bin/open \"$0\"",
            Bundle.main.bundlePath, String(ProcessInfo.processInfo.processIdentifier),
        ]
        try? task.run()
        terminate(nil)
    }
}
