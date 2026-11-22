import AppKit
import Observation
import os

/// Sets the fans the way the user picked, through CleanBar's helper (`FanHelperService`), which macOS asks to install the
/// first time. With the fans left to macOS, CleanBar isn't connected to the helper at all, and the helper isn't running.
///
/// What's picked lasts until CleanBar next opens, which goes back to the user's default (`AppSettings.fanDefaultMode`).
@Observable
final class FanController {
    /// Who decides how fast the fans turn now.
    private(set) var mode: FanMode
    /// The profile the rules call for now, on Automatic.
    private(set) var ruleProfile: FanProfile?
    /// The rules whose conditions are met now, on Automatic, which the settings show next to them.
    private(set) var applyingRules: Set<FanRule.ID> = []
    /// Why the fans couldn't be changed the last time, until they can be again.
    private(set) var problem: String?
    /// Whether some other app is setting the fans, like iStat Menus or Macs Fan Control. CleanBar leaves them to it rather
    /// than having the fans go back and forth between the two. Only said once the fans have kept reading that way
    /// (`otherAppSettleTime`): they don't read as CleanBar left them for a moment after it changes them.
    private(set) var isHeldByAnotherApp = false
    private(set) var isHelperInstalled = FanHelperInstaller.isInstalled
    /// Whether the helper was needed, and it's not there, or it's older than this CleanBar. Installing it takes the
    /// password, which isn't asked for out of the blue, as when a rule starts to apply.
    private var helperIsMissing = false

    /// Asked to read the fans again, once they've changed.
    @ObservationIgnored var onChange: (() -> Void)?

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private var helper: FanHelperClient?
    @ObservationIgnored private var applyTask: Task<Void, Never>?
    /// Set while asking the helper. It can take a while: macOS may hold out for a few seconds, or ask for the password.
    @ObservationIgnored private var isApplying = false
    @ObservationIgnored private var evaluator = FanRuleEvaluator()
    /// The temperatures as last read, in °C by sensor.
    @ObservationIgnored private var temperatures: [String: Double] = [:]
    /// The speeds last asked for that didn't work out, so they aren't asked for again on each reading.
    @ObservationIgnored private var failedSpeeds: [Double]?
    /// Since when the fans have been reading as if another app had them.
    @ObservationIgnored private var fansLookTakenSince: Date?
    /// The fans as last read.
    private var fans: [FanReading] = []
    /// What the helper has the fans hold now, in rpm by fan.
    private var heldSpeeds: [Double]?

    private static let speedTolerance = 50.0
    private static let otherAppSettleTime: TimeInterval = 10
    private static let log = Logger(subsystem: FanHelperInfo.label, category: "CleanBar")

    init(settings: AppSettings) {
        self.settings = settings
        mode = settings.fanDefaultMode
    }

    /// Whether the rules decide now: without any, Automatic comes down to leaving the fans to macOS.
    var followsRules: Bool { mode == .automatic && !settings.fanRules.isEmpty }

    var isSystemControlled: Bool { mode == .system || (mode == .automatic && settings.fanRules.isEmpty) }

    /// Whether what the user set up can't work until the helper is installed.
    var needsHelper: Bool { helperIsMissing || (!isHelperInstalled && !settings.fanRules.isEmpty) }

    /// What the sensors list calls who decides how fast the fans turn.
    var summary: String {
        if isHeldByAnotherApp {
            return String(localized: "Another App")
        }
        switch mode {
        case .system:
            return String(localized: "System Controlled")
        case .automatic:
            guard followsRules else { return String(localized: "System Controlled") }
            return [String(localized: "Automatic"), ruleProfile?.name].compactMap(\.self).joined(separator: " · ")
        case .profile(let id):
            return settings.fanProfiles.first { $0.id == id }?.name ?? String(localized: "System Controlled")
        case .custom:
            return String(localized: "Custom")
        }
    }

    /// The speed to show for a fan on its slider, from 0 to 100: what it's set to, or else how fast it's turning.
    func percent(ofFan fan: FanReading) -> Double {
        switch mode {
        case .system:
            fan.percent
        case .automatic:
            ruleProfile?.speed(ofFan: fan.index) ?? fan.percent
        case .profile(let id):
            settings.fanProfiles.first { $0.id == id }?.speed(ofFan: fan.index) ?? fan.percent
        case .custom(let speeds):
            speeds.indices.contains(fan.index) ? speeds[fan.index] : fan.percent
        }
    }

    /// Lets macOS decide again, follows the rules, or has the fans hold a profile or the sliders' speeds. If it doesn't
    /// work out, as when the password is turned down, macOS keeps deciding.
    func select(_ mode: FanMode) {
        self.mode = mode
        failedSpeeds = nil
        forgetOtherApp()
        updateRuleProfile()
        requestApply(canInstall: true)
    }

    /// A slider moved: that fan goes to `percent`, and the others stay at what they're set to now.
    func setSpeed(_ percent: Double, ofFan fan: FanReading) {
        var speeds = fans.map { self.percent(ofFan: $0) }
        guard speeds.indices.contains(fan.index) else { return }
        speeds[fan.index] = percent
        select(.custom(speeds))
    }

    /// The profiles or the rules were edited: what the fans should do may be different now.
    func setupChanged() {
        if case .profile(let id) = mode, !settings.fanProfiles.contains(where: { $0.id == id }) {
            mode = settings.fanDefaultMode
        }
        failedSpeeds = nil
        updateRuleProfile()
        requestApply(canInstall: false)
    }

    /// The Sensors setting came on, or CleanBar opened with it on.
    func start() {
        mode = settings.fanDefaultMode
    }

    /// Back to macOS: the Sensors setting went off.
    func stop() {
        mode = .system
        fans = []
        forgetRules()
        requestApply(canInstall: false)
    }

    /// The fans and sensors were read again: it may be time for what the user picked, as at the first reading. A rule may
    /// have started or stopped applying, or a fan may have gone back to macOS's control, as they do when the Mac wakes up.
    func readingsChanged(fans: [FanReading], temperatures: [String: Double]) {
        self.fans = fans
        self.temperatures = temperatures
        guard !fans.isEmpty, !isApplying else { return }
        updateHeldByAnotherApp()
        updateRuleProfile()
        applyIfNeeded()
    }

    /// Installs the helper, for when `needsHelper` says it's time to.
    func installHelper() {
        let previous = applyTask
        applyTask = Task { [weak self] in
            await previous?.value
            guard let self, await self.connectedHelper(canInstall: true) != nil else { return }
            self.failedSpeeds = nil
            // Hangs up again if there's nothing for the fans to do yet.
            await self.apply(canInstall: false)
        }
    }

    /// Takes the helper off this Mac.
    func removeHelper() {
        mode = .system
        forgetRules()
        let previous = applyTask
        applyTask = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await self.letFansGo()
            do {
                try await FanHelperInstaller.uninstall()
                self.problem = nil
            } catch FanHelperInstaller.Failure.cancelled {
                // Nothing changed.
            } catch {
                Self.log.error("Couldn't remove the fan helper: \(String(describing: error))")
                self.problem = String(localized: "macOS didn't let CleanBar remove its fan helper.")
            }
            self.isHelperInstalled = FanHelperInstaller.isInstalled
        }
    }

    // MARK: Applying

    /// Whether the fans hold a speed nobody here asked for, as of the last reading.
    private var fansLookTaken: Bool {
        guard let heldSpeeds else {
            return (mode == .system || mode == .automatic) && fans.contains(where: \.isHeld)
        }
        return zip(fans, heldSpeeds).contains { fan, speed in
            fan.isHeld && abs((fan.target ?? speed) - speed) > Self.speedTolerance
        }
    }

    private func updateHeldByAnotherApp() {
        guard fansLookTaken else {
            if let since = fansLookTakenSince {
                let seconds = Date.now.timeIntervalSince(since)
                Self.log.notice("The fans read as expected again after \(seconds, format: .fixed(precision: 1), privacy: .public) s")
            }
            forgetOtherApp()
            return
        }
        let since = fansLookTakenSince ?? .now
        if fansLookTakenSince == nil {
            let readings = fans.map { "\($0.isHeld ? "held" : "free") at \(Int($0.target ?? -1))" }.joined(separator: ", ")
            let expected = heldSpeeds?.map { String(Int($0)) }.joined(separator: ", ") ?? "none"
            Self.log.notice("The fans don't read as expected: \(readings, privacy: .public); CleanBar set: \(expected, privacy: .public)")
        }
        fansLookTakenSince = since
        let isHeld = Date.now.timeIntervalSince(since) >= Self.otherAppSettleTime
        if isHeld != isHeldByAnotherApp {
            isHeldByAnotherApp = isHeld
        }
    }

    /// The fans are about to change, or read as expected, so whatever they read before says nothing about other apps.
    private func forgetOtherApp() {
        fansLookTakenSince = nil
        if isHeldByAnotherApp {
            isHeldByAnotherApp = false
        }
    }

    private func updateRuleProfile() {
        guard followsRules else {
            forgetRules()
            evaluator = FanRuleEvaluator()
            return
        }
        let rules = settings.fanRules
        let profile = evaluator.profile(
            rules: rules,
            profiles: settings.fanProfiles,
            temperatures: temperatures,
            states: rules.contains(where: \.goesByState) ? MacState.current : [],
            fanCount: fans.count,
            at: .now
        )
        if profile != ruleProfile {
            ruleProfile = profile
        }
        if evaluator.applyingRules != applyingRules {
            applyingRules = evaluator.applyingRules
        }
    }

    private func forgetRules() {
        ruleProfile = nil
        if !applyingRules.isEmpty {
            applyingRules = []
        }
    }

    private func applyIfNeeded() {
        guard let wanted = wantedSpeeds else {
            failedSpeeds = nil
            if heldSpeeds != nil {
                requestApply(canInstall: false)
            }
            return
        }
        if wanted == heldSpeeds {
            if fans.contains(where: { !$0.isHeld }) {
                requestApply(canInstall: false)
            }
        } else if wanted != failedSpeeds, !(mode == .automatic && fansLookTaken) {
            // A rule never takes the fans from another app, not even before that's been said out loud.
            requestApply(canInstall: false)
        }
    }

    private func requestApply(canInstall: Bool) {
        let previous = applyTask
        applyTask = Task { [weak self] in
            await previous?.value
            await self?.apply(canInstall: canInstall)
        }
    }

    private func apply(canInstall: Bool) async {
        isApplying = true
        forgetOtherApp()
        defer {
            isApplying = false
            forgetOtherApp()
            onChange?()
        }
        guard let speeds = wantedSpeeds else {
            await letFansGo()
            problem = nil
            return
        }
        guard let helper = await connectedHelper(canInstall: canInstall) else {
            leaveFansToSystem(wanted: speeds)
            return
        }
        if await helper.setFanSpeeds(speeds) {
            heldSpeeds = speeds
            failedSpeeds = nil
            // As they'll read from now on, so until they do they aren't taken for another app's.
            for (index, speed) in zip(fans.indices, speeds) {
                fans[index].target = speed
                fans[index].isHeld = true
            }
            problem = nil
        } else {
            problem = String(localized: "macOS didn't let CleanBar change the fans, so macOS keeps controlling them.")
            leaveFansToSystem(wanted: speeds)
            await letFansGo()
        }
    }

    /// Couldn't set the fans. What was picked by hand gives way to macOS, which is what's happening. Rules stay in place,
    /// to try again once they call for something else.
    private func leaveFansToSystem(wanted speeds: [Double]) {
        failedSpeeds = speeds
        if mode != .automatic {
            mode = .system
        }
    }

    /// The speed each fan should hold now in rpm, or nil when that's up to macOS.
    private var wantedSpeeds: [Double]? {
        guard !fans.isEmpty else { return nil }
        switch mode {
        case .system:
            return nil
        case .automatic:
            guard let ruleProfile else { return nil }
            return fans.map { $0.rpm(forPercent: ruleProfile.speed(ofFan: $0.index)) }
        case .profile(let id):
            guard let profile = settings.fanProfiles.first(where: { $0.id == id }) else { return nil }
            return fans.map { $0.rpm(forPercent: profile.speed(ofFan: $0.index)) }
        case .custom(let speeds):
            return fans.map { $0.rpm(forPercent: speeds.indices.contains($0.index) ? speeds[$0.index] : $0.percent) }
        }
    }

    /// Hangs up on the helper, which gives the fans back to macOS.
    private func letFansGo() async {
        heldSpeeds = nil
        guard let helper else { return }
        self.helper = nil
        await helper.restoreAutomatic()
        helper.disconnect()
    }

    /// The helper, ready to use. If it isn't installed, or an older one is, `canInstall` says whether to install it, for
    /// which macOS asks for the password. Nil if that didn't work out.
    private func connectedHelper(canInstall: Bool) async -> FanHelperClient? {
        if let helper { return helper }
        if let helper = await FanHelperClient.connect() {
            self.helper = helper
            helperIsMissing = false
            return helper
        }
        guard canInstall else {
            helperIsMissing = true
            return nil
        }
        do {
            try await FanHelperInstaller.install()
        } catch FanHelperInstaller.Failure.cancelled {
            return nil
        } catch {
            Self.log.error("Couldn't install the fan helper: \(String(describing: error))")
            problem = String(localized: "macOS didn't let CleanBar install its fan helper.")
            return nil
        }
        isHelperInstalled = FanHelperInstaller.isInstalled
        // launchd starts it when it's first asked, which may take a moment after installing it.
        for _ in 0..<5 {
            if let helper = await FanHelperClient.connect() {
                self.helper = helper
                helperIsMissing = false
                return helper
            }
            try? await Task.sleep(for: .seconds(1))
        }
        problem = String(localized: "CleanBar's fan helper didn't start. Check that it's allowed in System Settings → General → Login Items & Extensions.")
        return nil
    }
}

/// CleanBar's end of a connection to its fan helper. `NSXPCConnection` can be used from any thread.
nonisolated final class FanHelperClient: @unchecked Sendable {
    private let connection: NSXPCConnection
    /// How long to wait for the helper to start, and to take the fans from macOS, which can take up to 10 seconds per try.
    private static let startTimeout: TimeInterval = 5
    private static let setTimeout: TimeInterval = 25

    private init() {
        connection = NSXPCConnection(machServiceName: FanHelperInfo.label, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: FanHelperInterface.self)
        connection.resume()
    }

    /// Connects to the helper, if the one installed is running and is the one this CleanBar came with.
    static func connect() async -> FanHelperClient? {
        let client = FanHelperClient()
        let version: Int = await client.ask(timeout: startTimeout, otherwise: 0) { helper, reply in helper.version(reply: reply) }
        if version == FanHelperInfo.version {
            return client
        }
        client.disconnect()
        return nil
    }

    func disconnect() {
        connection.invalidate()
    }

    func setFanSpeeds(_ speeds: [Double]) async -> Bool {
        await ask(timeout: Self.setTimeout, otherwise: false) { helper, reply in helper.setFanSpeeds(speeds, reply: reply) }
    }

    func restoreAutomatic() async {
        let _: Bool = await ask(timeout: Self.startTimeout, otherwise: false) { helper, reply in
            helper.restoreAutomatic { reply(true) }
        }
    }

    /// Asks the helper something and waits for the reply, or for `otherwise` when the connection fails or it takes too long.
    private func ask<Reply: Sendable>(
        timeout: TimeInterval,
        otherwise: Reply,
        _ question: @Sendable (FanHelperInterface, @escaping @Sendable (Reply) -> Void) -> Void
    ) async -> Reply {
        await withCheckedContinuation { continuation in
            let isAnswered = OSAllocatedUnfairLock(initialState: false)
            let answer: @Sendable (Reply) -> Void = { reply in
                let isFirst = isAnswered.withLock { isAnswered in
                    defer { isAnswered = true }
                    return !isAnswered
                }
                if isFirst {
                    continuation.resume(returning: reply)
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { answer(otherwise) }
            let helper = connection.remoteObjectProxyWithErrorHandler { _ in answer(otherwise) }
            if let helper = helper as? FanHelperInterface {
                question(helper, answer)
            } else {
                answer(otherwise)
            }
        }
    }
}

/// Puts CleanBar's fan helper where launchd runs it from, as root, or takes it away. That's the classic way, through an
/// administrator's password: macOS's newer ones (`SMAppService`, `SMJobBless`) only work for apps with a Developer ID, and
/// CleanBar is signed ad hoc. The helper is copied out of CleanBar, to a folder only root can write to, since a tool that
/// runs as root mustn't stay somewhere others could replace it.
nonisolated enum FanHelperInstaller {
    enum Failure: Error {
        case cancelled
        case failed(String)
    }

    private static let installedPath = "/Library/PrivilegedHelperTools/\(FanHelperInfo.label)"
    private static let launchdPlistPath = "/Library/LaunchDaemons/\(FanHelperInfo.label).plist"
    private static let serviceName = "system/\(FanHelperInfo.label)"
    private static let launchctl = "/bin/launchctl"

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: installedPath) && FileManager.default.fileExists(atPath: launchdPlistPath)
    }

    /// Where it is inside CleanBar.
    private static var bundledPath: String {
        Bundle.main.bundleURL.appending(path: "Contents/Library/LaunchServices/\(FanHelperInfo.label)").path
    }

    static func install() async throws {
        try await runAsAdministrator(
            installScript(helperPath: bundledPath),
            prompt: String(localized: "CleanBar needs your password to install its fan helper, which lets it change the speed of your Mac's fans.")
        )
    }

    static func uninstall() async throws {
        try await runAsAdministrator(
            uninstallScript,
            prompt: String(localized: "CleanBar needs your password to remove its fan helper.")
        )
    }

    /// One line, for AppleScript. launchd may need a moment after letting go of the helper it's replacing. The helper runs
    /// when CleanBar connects, so nothing is left running.
    private static func installScript(helperPath: String) -> String {
        [
            "\(launchctl) bootout \(serviceName) 2>/dev/null",
            "/bin/mkdir -p /Library/PrivilegedHelperTools",
            "/usr/bin/install -o root -g wheel -m 555 \(shellQuoted(helperPath)) \(installedPath) || exit 1",
            "/usr/bin/xattr -c \(installedPath)",
            "/usr/bin/printf '%s' \(shellQuoted(launchdPlist)) > \(launchdPlistPath) || exit 1",
            "/usr/sbin/chown root:wheel \(launchdPlistPath)",
            "/bin/chmod 644 \(launchdPlistPath)",
            "for attempt in 1 2 3 4 5; do \(launchctl) bootstrap system \(launchdPlistPath) && exit 0; /bin/sleep 1; done",
            "exit 1",
        ].joined(separator: "; ")
    }

    private static var uninstallScript: String {
        "\(launchctl) bootout \(serviceName) 2>/dev/null; /bin/rm -f \(launchdPlistPath) \(installedPath)"
    }

    /// What launchd needs to know: it starts the helper when something connects to its Mach service, and not before.
    private static var launchdPlist: String {
        let plist: [String: Any] = [
            "Label": FanHelperInfo.label,
            "Program": installedPath,
            "MachServices": [FanHelperInfo.label: true],
            "AssociatedBundleIdentifiers": [Bundle.main.bundleIdentifier ?? "com.cleanbar.CleanBar"],
        ]
        let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        return data.map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    private static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptQuoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Asks with macOS's own password dialog, through AppleScript. In a process of its own, since that waits for the dialog.
    private static func runAsAdministrator(_ script: String, prompt: String) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
            "-e", "do shell script \(appleScriptQuoted(script)) with administrator privileges with prompt \(appleScriptQuoted(prompt))",
        ]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { process in
                let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                if process.terminationStatus == 0 {
                    continuation.resume()
                } else if message.contains("-128") {
                    // AppleScript's way of saying the dialog was turned down.
                    continuation.resume(throwing: Failure.cancelled)
                } else {
                    continuation.resume(throwing: Failure.failed(message))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: Failure.failed(error.localizedDescription))
            }
        }
    }
}
