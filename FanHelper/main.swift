import Foundation
import os

/// CleanBar's fan helper. macOS only lets root change the fans, so this small tool runs as root, from
/// /Library/PrivilegedHelperTools, and does that one thing (`FanHelperInterface`).
///
/// launchd starts it when CleanBar connects. CleanBar only connects while the user has set a fan speed. Once CleanBar is
/// gone, however that happened, the helper gives the fans back to macOS and quits.
///
/// Taking a fan from macOS follows what people found out about Apple silicon's fans. On M1 and M5, setting a fan's mode
/// to 1 is enough. On chips with the `Ftst` key, like M4, macOS's `thermalmonitord` refuses that until `Ftst` is 1, and
/// then gives way within a few seconds.
final class FanHelperService: NSObject, NSXPCListenerDelegate, FanHelperInterface, @unchecked Sendable {
    private static let log = Logger(subsystem: FanHelperInfo.label, category: "fans")
    /// launchd starts jobs at most once every 10 seconds, so quitting sooner would hold up the next connection.
    private static let idleTime: TimeInterval = 30
    /// How long `thermalmonitord` can take to give way, and how often to try meanwhile.
    private static let unlockTimeout: TimeInterval = 10
    private static let unlockRetry: useconds_t = 100_000
    private static let unlockKey = "Ftst"

    /// Everything that touches the SMC or the state below goes through this queue.
    private let queue = DispatchQueue(label: "\(FanHelperInfo.label).fans")
    private let smc = SMC()
    private var connectionCount = 0
    /// Set while this helper has the fans, so it never takes them back from another app that has them.
    private var isHoldingFans = false
    private var quitWork: DispatchWorkItem?
    private var terminationSource: DispatchSourceSignal?

    override init() {
        super.init()
        quitWhenIdle()
        // launchd asks with this when stopping the helper, as when the Mac shuts down.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
        source.setEventHandler { [self] in
            giveFansBack()
            exit(EXIT_SUCCESS)
        }
        source.resume()
        terminationSource = source
    }

    // MARK: Connections

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // Someone else logged in on this Mac has no business with the fans of the person using it.
        guard connection.effectiveUserIdentifier == Self.consoleUser else {
            Self.log.error("Refused a connection from user \(connection.effectiveUserIdentifier)")
            return false
        }
        connection.exportedInterface = NSXPCInterface(with: FanHelperInterface.self)
        connection.exportedObject = self
        connection.invalidationHandler = { [self] in
            queue.async { [self] in connectionEnded() }
        }
        queue.async { [self] in
            connectionCount += 1
            quitWork?.cancel()
        }
        connection.resume()
        return true
    }

    private func connectionEnded() {
        connectionCount -= 1
        guard connectionCount == 0 else { return }
        giveFansBack()
        quitWhenIdle()
    }

    private func quitWhenIdle() {
        let work = DispatchWorkItem { exit(EXIT_SUCCESS) }
        quitWork = work
        queue.asyncAfter(deadline: .now() + Self.idleTime, execute: work)
    }

    /// Who owns the console is who's using the Mac right now.
    private static var consoleUser: uid_t? {
        var info = stat()
        return stat("/dev/console", &info) == 0 ? info.st_uid : nil
    }

    // MARK: FanHelperInterface

    func version(reply: @escaping @Sendable (Int) -> Void) {
        reply(FanHelperInfo.version)
    }

    func setFanSpeeds(_ speeds: [Double], reply: @escaping @Sendable (Bool) -> Void) {
        queue.async { [self] in
            reply(apply(speeds))
        }
    }

    func restoreAutomatic(reply: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            giveFansBack()
            reply()
        }
    }

    // MARK: The fans

    private func apply(_ speeds: [Double]) -> Bool {
        guard let smc, smc.fanCount > 0, speeds.count == smc.fanCount else {
            Self.log.error("Asked for \(speeds.count) fan speeds, for \(self.smc?.fanCount ?? 0) fans")
            return false
        }
        // Set before the first change, so a failure on a later fan gives back the earlier ones too.
        isHoldingFans = true
        for (fan, speed) in speeds.enumerated() {
            guard let target = target(speed, fan: fan, in: smc), takeFan(fan, in: smc), setTarget(target, fan: fan, in: smc) else {
                Self.log.error("Couldn't set fan \(fan) to \(speed) rpm")
                giveFansBack()
                return false
            }
        }
        return true
    }

    /// The speed within the fan's limits, or nil if there's no telling what they are.
    private func target(_ speed: Double, fan: Int, in smc: SMC) -> Double? {
        guard speed.isFinite, let minimum = smc.float("F\(fan)Mn"), let maximum = smc.float("F\(fan)Mx"), minimum < maximum else {
            return nil
        }
        return min(max(speed, minimum), maximum)
    }

    private func takeFan(_ fan: Int, in smc: SMC) -> Bool {
        guard let key = smc.fanModeKey(fan) else { return false }
        if smc.byte(key) == 1 || smc.write(key, byte: 1) { return true }
        guard smc.has(Self.unlockKey), smc.write(Self.unlockKey, byte: 1) else { return false }
        let deadline = Date.now + Self.unlockTimeout
        while Date.now < deadline {
            if smc.write(key, byte: 1) { return true }
            usleep(Self.unlockRetry)
        }
        return false
    }

    /// Some chips answer with an error even when they take the value, so what counts is what the fan reads afterwards.
    private func setTarget(_ target: Double, fan: Int, in smc: SMC) -> Bool {
        let key = "F\(fan)Tg"
        if smc.write(key, float: target) { return true }
        return smc.float(key).map { abs($0 - target) < 1 } ?? false
    }

    private func giveFansBack() {
        guard isHoldingFans, let smc else { return }
        isHoldingFans = false
        for fan in 0..<smc.fanCount {
            guard let key = smc.fanModeKey(fan), smc.write(key, byte: 0) else {
                Self.log.error("Couldn't give fan \(fan) back to macOS")
                continue
            }
            // The target of a fan macOS runs is up to macOS, whatever it's set to. A fan still in our hands would stop.
            _ = smc.write("F\(fan)Tg", float: 0)
        }
        if smc.byte(Self.unlockKey) == 1 {
            _ = smc.write(Self.unlockKey, byte: 0)
        }
    }
}

let service = FanHelperService()
let listener = NSXPCListener(machServiceName: FanHelperInfo.label)
listener.delegate = service
listener.setConnectionCodeSigningRequirement(FanHelperInfo.clientRequirement)
listener.resume()
dispatchMain()
