import AppKit

// CleanBar is a menu bar agent (LSUIElement), so it's started by hand instead of through a SwiftUI `App`.
let appDelegate = AppDelegate()
NSApplication.shared.delegate = appDelegate
NSApplication.shared.run()
