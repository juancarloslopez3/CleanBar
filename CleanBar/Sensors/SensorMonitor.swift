import Foundation
import Observation

/// What the sensors and fans read at one moment.
nonisolated struct SensorReadout: Sendable {
    var sensors: [TemperatureSensor] = []
    /// In °C, by sensor.
    var temperatures: [String: Double] = [:]
    var fans: [FanReading] = []
}

/// Reads the SMC, off the main thread. A read of everything takes a few milliseconds.
actor SensorReader {
    private let smc = SMC()
    /// Found the first time: the keys this Mac has don't change while it runs.
    private var sensors: [TemperatureSensor]?

    func read() -> SensorReadout {
        guard let smc else { return SensorReadout() }
        let sensors = self.sensors ?? SensorCatalog.sensors(forChip: SensorCatalog.chipName) { key in
            smc.float(key).map(Self.isPlausible) ?? false
        }
        self.sensors = sensors

        var temperatures: [String: Double] = [:]
        var coreTotal = 0.0
        var coreCount = 0.0
        for sensor in sensors where sensor.id != TemperatureSensor.cpuAverageID {
            let readings = (sensor.averaged.isEmpty ? [sensor.id] : sensor.averaged).compactMap(smc.float).filter(Self.isPlausible)
            guard !readings.isEmpty else { continue }
            let temperature = readings.reduce(0, +) / Double(readings.count)
            temperatures[sensor.id] = temperature
            if sensor.group == .cpu {
                coreTotal += temperature
                coreCount += 1
            }
        }
        if coreCount > 0 {
            temperatures[TemperatureSensor.cpuAverageID] = coreTotal / coreCount
        }
        return SensorReadout(sensors: sensors, temperatures: temperatures, fans: readFans(smc))
    }

    /// Keys that exist but aren't wired to anything read 0.
    private static func isPlausible(_ temperature: Double) -> Bool {
        temperature > 1 && temperature < 150
    }

    private func readFans(_ smc: SMC) -> [FanReading] {
        let fanCount = smc.fanCount
        return (0..<fanCount).compactMap { fan in
            guard let rpm = smc.float("F\(fan)Ac"), let minimum = smc.float("F\(fan)Mn"), let maximum = smc.float("F\(fan)Mx") else {
                return nil
            }
            return FanReading(
                index: fan,
                fanCount: fanCount,
                rpm: rpm,
                target: smc.float("F\(fan)Tg"),
                minimum: minimum,
                maximum: maximum,
                isHeld: smc.fanModeKey(fan).flatMap(smc.byte) == 1
            )
        }
    }
}

/// Keeps the latest readings of the Mac's sensors and fans while the Sensors setting is on, and their history.
@Observable
final class SensorMonitor {
    private(set) var sensors: [TemperatureSensor] = []
    /// In °C, by sensor.
    private(set) var temperatures: [String: Double] = [:]
    private(set) var fans: [FanReading] = []
    private(set) var isRunning = false

    /// Seconds between readings. History wants them regular, however long the Mac is left alone.
    enum Pace: Double {
        /// While the sensors list is open.
        case often = 2
        /// Often enough to follow in the menu bar, and for rules to act on.
        case regular = 5
        /// When nothing's showing the readings, only history wants them. That's still often enough for its chart not to
        /// show gaps (`SensorHistoryView`).
        case seldom = 30
    }

    @ObservationIgnored let history = SensorHistory()
    @ObservationIgnored var onRead: (() -> Void)?
    @ObservationIgnored var pace = Pace.regular {
        didSet { if pace != oldValue, isRunning { readNow() } }
    }

    @ObservationIgnored private let reader = SensorReader()
    @ObservationIgnored private var readTask: Task<Void, Never>?
    /// Keeps macOS from slowing CleanBar's timers down while it has no windows open (App Nap). It doesn't keep the Mac
    /// awake.
    @ObservationIgnored private var activity: NSObjectProtocol?

    func start() {
        guard !isRunning else { return }
        isRunning = true
        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Reading the Mac's temperature sensors"
        )
        readNow()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        readTask?.cancel()
        readTask = nil
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
        }
        activity = nil
        history.save()
    }

    /// Reads right away, instead of at the next turn.
    func readNow() {
        guard isRunning else { return }
        readTask?.cancel()
        readTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let readout = await self.reader.read()
                guard !Task.isCancelled else { return }
                self.take(readout)
                let interval = self.pace.rawValue
                try? await Task.sleep(for: .seconds(interval), tolerance: .seconds(interval / 5))
            }
        }
    }

    private func take(_ readout: SensorReadout) {
        if sensors != readout.sensors {
            sensors = readout.sensors
        }
        temperatures = readout.temperatures
        fans = readout.fans
        var readings = readout.temperatures
        for fan in readout.fans {
            readings[fan.rowID] = fan.rpm
        }
        history.record(readings)
        onRead?()
    }

    // MARK: Rows

    /// Every fan and temperature sensor, in the order the user put them in. Those the user hasn't placed yet, like every
    /// one of them at first, go at the end, in the order they're read: fans, then what's hottest.
    func rows(order: [String]) -> [SensorRow] {
        let all = fans.map(SensorRow.init) + sensors.map(SensorRow.init)
        let places = Dictionary(order.enumerated().map { ($1, $0) }) { first, _ in first }
        return all.enumerated()
            .sorted { (places[$0.element.id] ?? .max, $0.offset) < (places[$1.element.id] ?? .max, $1.offset) }
            .map(\.element)
    }

    /// What a row reads now, as the list shows it.
    func value(of row: SensorRow) -> String {
        switch row.kind {
        case .fan(let index):
            guard let fan = fans.first(where: { $0.index == index }) else { return "—" }
            return String(localized: "\(Int(fan.rpm.rounded())) rpm")
        case .temperature(let sensor):
            return temperatures[sensor.id].map { TemperatureText.string($0) } ?? "—"
        }
    }

    /// How full a row's bar is, from 0 to 1.
    func level(of row: SensorRow) -> Double {
        switch row.kind {
        case .fan(let index):
            return (fans.first { $0.index == index }?.percent ?? 0) / 100
        case .temperature(let sensor):
            return min((temperatures[sensor.id] ?? 0) / sensor.group.ceiling, 1)
        }
    }
}
