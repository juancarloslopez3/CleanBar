import Foundation

/// What CleanBar can ask of its fan helper, over XPC. On purpose there's nothing else: whatever connects to it can only
/// set the fans to speeds their own limits allow, or give them back to macOS, never write to the SMC at will.
@objc nonisolated protocol FanHelperInterface {
    func version(reply: @escaping @Sendable (Int) -> Void)

    /// Has each fan hold a speed, in rpm, by fan. The helper keeps each one within its fan's limits. Replies whether it
    /// worked; if not, macOS has the fans.
    func setFanSpeeds(_ speeds: [Double], reply: @escaping @Sendable (Bool) -> Void)

    /// Gives the fans back to macOS. The helper also does this by itself once CleanBar is gone, even if it crashed.
    func restoreAutomatic(reply: @escaping @Sendable () -> Void)
}

nonisolated enum FanHelperInfo {
    /// The helper's launchd label, Mach service and file name.
    static let label = "com.cleanbar.CleanBar.FanHelper"

    /// Goes up when the helper changes, so CleanBar knows to install the new one.
    static let version = 1

    /// Who may connect. CleanBar is signed ad hoc, so other software could sign itself with this name too: this only turns
    /// away what connects by mistake. What keeps the helper safe is how little it can do (`FanHelperInterface`).
    static let clientRequirement = "identifier \"com.cleanbar.CleanBar\""
}
