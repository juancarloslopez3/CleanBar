import Foundation

/// What a temperature sensor measures, which says how hot it normally gets.
nonisolated enum SensorGroup: Sendable {
    case cpu
    case gpu
    case memory
    case storage
    case battery
    case wireless
    case airflow
    case palmRest

    /// The temperature a full bar stands for in the sensors list, in °C: a palm rest at 45° is hot, a CPU at 45° isn't.
    var ceiling: Double {
        switch self {
        case .cpu, .gpu: 105
        case .memory, .storage, .wireless: 90
        case .airflow: 70
        case .battery: 60
        case .palmRest: 50
        }
    }
}

/// The kinds of core a chip has, which the sensors list tells apart by their icons.
nonisolated enum CPUCoreKind: Sendable {
    case superCore
    case efficiency
    case performance
}

/// One of the Mac's temperature sensors.
nonisolated struct TemperatureSensor: Identifiable, Hashable, Sendable {
    /// Its SMC key, or `cpuAverageID`.
    let id: String
    let name: String
    let group: SensorGroup
    /// The kind of core it's on, if it's on one.
    var core: CPUCoreKind?
    /// The SMC keys it shows the average of, when it stands for more than one sensor, as the Mac's two palm rest
    /// sensors do. Its `id` is the first of them, which is what the row went by before they were merged.
    var averaged: [String] = []

    /// The average of the CPU's sensors, which isn't a sensor itself. It's what the menu bar shows unless the user picks
    /// another.
    static let cpuAverageID = "cpu.average"
    /// Picked instead of a sensor for the menu bar to show a symbol, with no temperature to keep up to date.
    static let noneID = "none"
}

/// A fan as last read.
nonisolated struct FanReading: Identifiable, Hashable, Sendable {
    let index: Int
    /// How many fans the Mac has, which decides what this one's called.
    let fanCount: Int
    var rpm: Double
    /// The speed it's been told to hold.
    var target: Double?
    let minimum: Double
    let maximum: Double
    /// Whether it holds the speed it's been told, instead of macOS running it.
    var isHeld: Bool

    var id: Int { index }

    /// What it goes by in the user's settings and in the history.
    var rowID: String { "fan.\(index)" }

    /// As in MacBook Pros, whose first fan is on the left.
    var name: String {
        switch fanCount {
        case 1: String(localized: "Fan")
        case 2: index == 0 ? String(localized: "Left Fan") : String(localized: "Right Fan")
        default: String(localized: "Fan \(index + 1)")
        }
    }

    /// How fast it's turning, from 0 at its minimum speed to 100 at its maximum.
    var percent: Double { percent(forRPM: rpm) }

    func percent(forRPM rpm: Double) -> Double {
        guard maximum > minimum else { return 0 }
        return min(max((rpm - minimum) / (maximum - minimum) * 100, 0), 100)
    }

    /// The speed for that percentage, in tens of rpm.
    func rpm(forPercent percent: Double) -> Double {
        ((minimum + (maximum - minimum) * percent / 100) / 10).rounded() * 10
    }
}

/// A row of the sensors list: a fan or a temperature sensor. Rows go by `id` in the user's settings.
nonisolated struct SensorRow: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case fan(Int)
        case temperature(TemperatureSensor)
    }

    let id: String
    let name: String
    let kind: Kind

    init(_ fan: FanReading) {
        id = fan.rowID
        name = fan.name
        kind = .fan(fan.index)
    }

    init(_ sensor: TemperatureSensor) {
        id = sensor.id
        name = sensor.name
        kind = .temperature(sensor)
    }

    var isFan: Bool {
        if case .fan = kind { return true }
        return false
    }
}

/// How fast the fans should turn, to pick from. CleanBar comes with `defaults`, which always stay as they are. The user can
/// add others, and name them.
nonisolated struct FanProfile: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    /// From 0 at a fan's minimum speed to 100 at its maximum, by fan. Fans past the end go by the first.
    var speeds: [Double]

    func speed(ofFan fan: Int) -> Double {
        speeds.indices.contains(fan) ? speeds[fan] : speeds.first ?? 50
    }

    mutating func setSpeed(_ speed: Double, ofFan fan: Int, fanCount: Int) {
        // Every fan gets its own value first, so the others stay as they are.
        speeds = (0..<max(fanCount, fan + 1, speeds.count)).map { self.speed(ofFan: $0) }
        speeds[fan] = speed
    }

    /// Adds up its speeds, to tell which of two profiles runs the fans faster.
    func totalSpeed(fanCount: Int) -> Double {
        (0..<max(fanCount, 1)).reduce(0) { $0 + speed(ofFan: $1) }
    }

    var isDefault: Bool { Self.defaults.contains { $0.id == id } }

    /// With ids that never change, as what's saved refers to them.
    static let defaults = [25, 50, 75, 100].map { percent in
        FanProfile(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", percent)) ?? UUID(),
            name: "\(percent)%",
            speeds: [Double(percent)]
        )
    }

    /// The first "Profile 1", "Profile 2"… that isn't taken.
    static func unusedName(among profiles: [FanProfile]) -> String {
        let names = Set(profiles.map(\.name))
        return (1...).lazy.map { String(localized: "Profile \($0)") }.first { !names.contains($0) } ?? ""
    }
}

/// Who decides how fast the fans turn.
nonisolated enum FanMode: Codable, Hashable, Sendable {
    /// macOS, as on any Mac.
    case system
    /// The user's rules (`FanRule`), and macOS while none of them applies.
    case automatic
    case profile(UUID)
    /// The speeds the user set with the sliders, from 0 to 100 by fan.
    case custom([Double])
}

/// How far back the history chart looks. Each range has its own samples: over a month, CleanBar keeps an average every two
/// hours, not every few seconds.
nonisolated enum HistoryRange: Int, CaseIterable, Identifiable, Sendable {
    case hour
    case day
    case week
    case month

    var id: Self { self }

    var title: String {
        switch self {
        case .hour: String(localized: "1 hour")
        case .day: String(localized: "24 hours")
        case .week: String(localized: "7 days")
        case .month: String(localized: "30 days")
        }
    }

    /// In seconds.
    var duration: Int {
        switch self {
        case .hour: 3600
        case .day: 86_400
        case .week: 604_800
        case .month: 2_592_000
        }
    }

    /// Seconds a sample stands for. Each range comes to about 350 samples, which is more than the chart has room to tell
    /// apart.
    var sampleLength: Int {
        switch self {
        case .hour: 10
        case .day: 300
        case .week: 1800
        case .month: 7200
        }
    }
}

/// A sample from the history of a sensor or a fan.
nonisolated struct HistoryPoint: Identifiable, Hashable, Sendable {
    let date: Date
    /// A sensor's in °C, a fan's in rpm.
    let value: Double

    var id: Date { date }
}

/// Temperatures the way the Mac shows them: in the unit under System Settings → General → Language & Region.
nonisolated enum TemperatureText {
    static func degrees(_ celsius: Double) -> Double {
        Measurement(value: celsius, unit: UnitTemperature.celsius).converted(to: UnitTemperature(forLocale: .current)).value
    }

    /// `degrees` in the Mac's unit.
    static func celsius(fromDegrees degrees: Double) -> Double {
        Measurement(value: degrees, unit: UnitTemperature(forLocale: .current)).converted(to: UnitTemperature.celsius).value
    }

    /// The Mac's unit, like "°C".
    static var unit: String { UnitTemperature(forLocale: .current).symbol }

    static func string(_ celsius: Double) -> String {
        string(degrees: degrees(celsius))
    }

    /// `degrees` already in the Mac's unit.
    static func string(degrees: Double) -> String {
        "\(Int(degrees.rounded()))°"
    }
}

/// Which SMC keys are which sensor. They differ from chip to chip and aren't documented: these are the ones the Stats app
/// has collected (github.com/exelban/stats, MIT license), and the ones iStat Menus turns out to show on an M1 Pro.
/// Each Mac only has some of them, and they're numbered as they're found.
nonisolated enum SensorCatalog {
    private struct ChipKeys {
        var superCores: [String] = []
        var efficiencyCores: [String]
        var performanceCores: [String]
        var gpu: [String]
    }

    private static let m1 = ChipKeys(
        efficiencyCores: ["Tp09", "Tp0T"],
        performanceCores: ["Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b"],
        gpu: ["Tg05", "Tg0D", "Tg0L", "Tg0T"]
    )
    private static let m2 = ChipKeys(
        efficiencyCores: ["Tp1h", "Tp1t", "Tp1p", "Tp1l"],
        performanceCores: ["Tp01", "Tp05", "Tp09", "Tp0D", "Tp0X", "Tp0b", "Tp0f", "Tp0j"],
        gpu: ["Tg0f", "Tg0j"]
    )
    private static let m3 = ChipKeys(
        efficiencyCores: ["Te05", "Te0L", "Te0P", "Te0S"],
        performanceCores: ["Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E", "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E"],
        gpu: ["Tf14", "Tf18", "Tf19", "Tf1A", "Tf24", "Tf28", "Tf29", "Tf2A"]
    )
    private static let m4 = ChipKeys(
        efficiencyCores: ["Te05", "Te0S", "Te09", "Te0H"],
        performanceCores: ["Tp01", "Tp05", "Tp09", "Tp0D", "Tp0V", "Tp0Y", "Tp0b", "Tp0e"],
        gpu: ["Tg0G", "Tg0H", "Tg1U", "Tg1k", "Tg0K", "Tg0L", "Tg0d", "Tg0e", "Tg0j", "Tg0k"]
    )
    private static let m5 = ChipKeys(
        superCores: ["Tp00", "Tp04", "Tp08", "Tp0C", "Tp0G", "Tp0K"],
        efficiencyCores: [],
        performanceCores: ["Tp0O", "Tp0R", "Tp0U", "Tp0X", "Tp0a", "Tp0d", "Tp0g", "Tp0j", "Tp0m", "Tp0p", "Tp0u", "Tp0y"],
        gpu: ["Tg0U", "Tg0X", "Tg0d", "Tg0g", "Tg0j", "Tg1Y", "Tg1c", "Tg1g"]
    )
    private static let m6 = ChipKeys(
        superCores: ["Tp0j", "Tp0g", "Tp09", "Tp07"],
        efficiencyCores: ["Te07", "Te08", "Te09", "Te0c", "Te0h", "Te0i"],
        performanceCores: ["Tp0m", "Tp0L", "Tp0I", "Tp0d", "Tp0E", "Tp0G", "Tp0b", "Tp05"],
        gpu: ["Tg1e", "Tg0d", "Tg0c", "Tg0b", "Tg1c", "Tg1d", "Tg07", "Tg1f", "Tg09", "Tg0a", "Tg1g", "Tg1h"]
    )
    private static let a18 = ChipKeys(
        efficiencyCores: ["Te05", "Te0S"],
        performanceCores: ["Tp05", "Tp0D"],
        gpu: ["Tg05", "Tg0D", "Tg0L", "Tg0e"]
    )

    /// The keys of a chip by its name, such as "Apple M1 Pro". A chip newer than CleanBar knows gets the newest it knows,
    /// so it may not show all its sensors, or may call them something else, until its keys are added.
    private static func keys(forChip name: String) -> ChipKeys {
        if name.contains("A18") { return a18 }
        let generation = name.firstMatch(of: /M(\d+)/).flatMap { Int($0.1) }
        return switch generation {
        case 1: m1
        case 2: m2
        case 3: m3
        case 4: m4
        case 5: m5
        default: m6
        }
    }

    /// This Mac's chip's name.
    static var chipName: String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var name = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &name, &size, nil, 0)
        return String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// The sensors of a chip that this Mac has, those it `reads`, in the order they first show in the list. The CPU's
    /// average comes first, then the CPU, the GPU, and what's around them.
    static func sensors(forChip chipName: String, reads: (String) -> Bool) -> [TemperatureSensor] {
        let chip = keys(forChip: chipName)
        func numbered(_ keys: [String], _ group: SensorGroup, core: CPUCoreKind? = nil, _ name: (Int) -> String) -> [TemperatureSensor] {
            keys.filter(reads).enumerated().map { index, key in
                TemperatureSensor(id: key, name: name(index + 1), group: group, core: core)
            }
        }
        /// One row for all the sensors of a part, which Apple doesn't say apart.
        func averaged(_ keys: [String], _ group: SensorGroup, _ name: String) -> [TemperatureSensor] {
            let found = keys.filter(reads)
            guard let id = found.first else { return [] }
            return [TemperatureSensor(id: id, name: name, group: group, averaged: found.count > 1 ? found : [])]
        }
        func first(of keys: [String], _ group: SensorGroup, _ name: String) -> [TemperatureSensor] {
            keys.first(where: reads).map { [TemperatureSensor(id: $0, name: name, group: group)] } ?? []
        }
        let cores = numbered(chip.superCores, .cpu, core: .superCore) { String(localized: "CPU Super Core \($0)") }
            + numbered(chip.efficiencyCores, .cpu, core: .efficiency) { String(localized: "CPU Efficiency Core \($0)") }
            + numbered(chip.performanceCores, .cpu, core: .performance) { String(localized: "CPU Performance Core \($0)") }
        let average = cores.isEmpty ? [] : [
            TemperatureSensor(id: TemperatureSensor.cpuAverageID, name: String(localized: "CPU Core Average"), group: .cpu),
        ]
        return average + cores
            + numbered(chip.gpu, .gpu) { String(localized: "GPU \($0)") }
            + numbered(["Tm02", "Tm06", "Tm08", "Tm09", "Tm0p", "Tm1p", "Tm2p"], .memory) { String(localized: "Memory \($0)") }
            + first(of: ["TH0x", "TH0a", "TH0b"], .storage, String(localized: "SSD"))
            + first(of: ["TB0T", "TB1T", "TB2T"], .battery, String(localized: "Battery"))
            + first(of: ["TW0P"], .wireless, String(localized: "Wi-Fi"))
            + averaged(["TaLP", "TaRF"], .airflow, String(localized: "Airflow"))
            + averaged(["Ts0P", "Ts1P"], .palmRest, String(localized: "Palm Rest"))
    }
}
