import Foundation
import IOKit
import IOKit.ps

/// Something about the Mac that a fan rule can go by, besides how hot it is.
nonisolated enum MacState: String, Codable, CaseIterable, Identifiable, Sendable {
    case charging
    case onBattery
    case pluggedIn
    case lowPowerMode
    case lidClosed
    /// macOS itself says the Mac is too hot: it's slowing things down to cool off.
    case overheating

    var id: Self { self }

    var title: String {
        switch self {
        case .charging: String(localized: "Battery Charging")
        case .onBattery: String(localized: "On Battery")
        case .pluggedIn: String(localized: "Plugged In")
        case .lowPowerMode: String(localized: "Low Power Mode")
        case .lidClosed: String(localized: "Lid Closed")
        case .overheating: String(localized: "Overheating")
        }
    }

    /// A tooltip for the states that aren't obvious from their name.
    var help: String? {
        switch self {
        case .overheating:
            String(localized: "macOS says the Mac is too hot and is slowing it down to cool off (thermal state Serious or Critical). It's not a set temperature, and it usually comes on after the Mac has been hot for a while.")
        default: nil
        }
    }

    /// Where the power comes from. A rule only needs one of these: on battery rules out the other two, and charging already
    /// means plugged in.
    private var isAboutPower: Bool {
        switch self {
        case .charging, .onBattery, .pluggedIn: true
        case .lowPowerMode, .lidClosed, .overheating: false
        }
    }

    /// Whether a rule can ask for both: they can be so at the same time, and each says something the other doesn't.
    func goes(with other: MacState) -> Bool {
        self != other && !(isAboutPower && other.isAboutPower)
    }

    /// The ones this Mac can be in: a desktop Mac has no battery or lid, and is always plugged in.
    static var available: [MacState] {
        hasBattery ? allCases : [.lowPowerMode, .overheating]
    }

    /// The ones the Mac is in now.
    static var current: Set<MacState> {
        var states: Set<MacState> = []
        let info = ProcessInfo.processInfo
        if info.isLowPowerModeEnabled { states.insert(.lowPowerMode) }
        if info.thermalState == .serious || info.thermalState == .critical { states.insert(.overheating) }
        if isLidClosed { states.insert(.lidClosed) }

        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return states }
        let source = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() as String?
        states.insert(source == kIOPSBatteryPowerValue ? .onBattery : .pluggedIn)
        if batteries(in: snapshot).contains(where: { $0[kIOPSIsChargingKey] as? Bool == true }) {
            states.insert(.charging)
        }
        return states
    }

    private static let hasBattery = IOPSCopyPowerSourcesInfo().map { !batteries(in: $0.takeRetainedValue()).isEmpty } ?? false

    private static func batteries(in snapshot: CFTypeRef) -> [[String: Any]] {
        let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] ?? []
        return sources.compactMap { IOPSGetPowerSourceDescription(snapshot, $0)?.takeUnretainedValue() as? [String: Any] }
            .filter { $0[kIOPSTypeKey] as? String == kIOPSInternalBatteryType }
    }

    private static var isLidClosed: Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        let state = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        return state?.takeRetainedValue() as? Bool == true
    }
}

/// Runs the fans at a profile when something about the Mac calls for it, while the fans are on Automatic.
nonisolated struct FanRule: Codable, Identifiable, Hashable, Sendable {
    enum Trigger: Codable, Hashable, Sendable {
        /// When any of the sensors is over the rule's temperature.
        case anySensor
        /// When that sensor is over the rule's temperature.
        case sensor(String)
        /// When the Mac is in that state.
        case state(MacState)

        var goesByTemperature: Bool {
            if case .state = self { return false }
            return true
        }
    }

    var id = UUID()
    var profile: FanProfile.ID
    var trigger = Trigger.anySensor
    /// In °C, for the triggers that go by temperature. It stays when the trigger changes, so changing back keeps it.
    var temperature = 70.0
    /// What has to be so as well. Nil for anything.
    var alsoWhen: MacState?

    /// As low and as high as makes sense for a rule, in °C.
    static let temperatures: ClosedRange<Double> = 30...110

    /// Whether it takes finding out what state the Mac is in.
    var goesByState: Bool { !trigger.goesByTemperature || alsoWhen != nil }

    /// Whether its two conditions go together. Only two states can clash: anything can be so at any temperature.
    var isSensible: Bool {
        guard case .state(let state) = trigger, let alsoWhen else { return true }
        return state.goes(with: alsoWhen)
    }

    /// Whether it applies at the same times as `other`, whichever way round its conditions are. Temperatures count as the same
    /// when they show as the same.
    func hasSameConditions(as other: FanRule) -> Bool {
        if case .state(let state) = trigger, case .state(let otherState) = other.trigger {
            return Set([state, alsoWhen].compactMap(\.self)) == Set([otherState, other.alsoWhen].compactMap(\.self))
        }
        return trigger == other.trigger && alsoWhen == other.alsoWhen
            && TemperatureText.degrees(temperature).rounded() == TemperatureText.degrees(other.temperature).rounded()
    }

    /// Whether it can be a rule next to `others`. One on a temperature can always get there, with `clear(of:)`.
    func isAllowed(among others: [FanRule]) -> Bool {
        isSensible && (trigger.goesByTemperature || !others.contains(where: hasSameConditions))
    }

    /// This rule, with the nearest temperature that doesn't make it repeat one of `others`: its own if that's fine, otherwise
    /// the next round step up, then down, then any at all.
    func clear(of others: [FanRule]) -> FanRule {
        guard trigger.goesByTemperature else { return self }
        let limits = Self.temperatures
        let candidates = Array(stride(from: temperature, through: limits.upperBound, by: 5))
            + Array(stride(from: temperature - 5, through: limits.lowerBound, by: -5))
            + Array(stride(from: limits.lowerBound, through: limits.upperBound, by: 1))
        for candidate in candidates {
            var moved = self
            moved.temperature = candidate
            if !others.contains(where: moved.hasSameConditions) {
                return moved
            }
        }
        return self
    }

    /// Saved rules as they'd be had the settings never let them clash, doing just what they did: a repeated or implied condition
    /// goes, as does a rule that can never apply, and of rules with the same conditions the fastest profile stays, as that's
    /// the one the fans were following.
    static func cleaned(_ rules: [FanRule], profiles: [FanProfile]) -> [FanRule] {
        let fanCount = profiles.map(\.speeds.count).max() ?? 1
        func speed(of rule: FanRule) -> Double {
            profiles.first { $0.id == rule.profile }?.totalSpeed(fanCount: fanCount) ?? -1
        }
        var kept: [FanRule] = []
        for rule in rules {
            guard let rule = rule.withoutClash else { continue }
            if let index = kept.firstIndex(where: rule.hasSameConditions) {
                if speed(of: rule) > speed(of: kept[index]) {
                    kept[index].profile = rule.profile
                }
            } else {
                kept.append(rule)
            }
        }
        return kept
    }

    /// The same rule with one condition, when its second says nothing more. Nil when the two can't be so at the same time.
    private var withoutClash: FanRule? {
        guard case .state(let state) = trigger, let alsoWhen, !state.goes(with: alsoWhen) else { return self }
        var rule = self
        rule.alsoWhen = nil
        if state == alsoWhen {
            return rule
        }
        guard Set([state, alsoWhen]) == [.charging, .pluggedIn] else { return nil }
        rule.trigger = .state(.charging)
        return rule
    }
}

/// Works out which profile the rules call for as the readings come in.
///
/// A rule on a temperature doesn't stop applying as soon as the temperature drops below it: the Mac's sensors jump around,
/// so the fans would keep speeding up and slowing down. It has to get `coolingMargin` lower, and stay there for `holdTime`.
nonisolated struct FanRuleEvaluator {
    static let coolingMargin = 3.0
    static let holdTime: TimeInterval = 30

    /// The rules that applied the last time the profile was worked out.
    private(set) var applyingRules: Set<FanRule.ID> = []
    /// The rules on a temperature that apply now, with when they were last hot enough.
    private var lastHot: [FanRule.ID: Date] = [:]

    /// The fastest profile of the rules that apply, as the fans can only follow one. The first of them when it's a tie.
    mutating func profile(
        rules: [FanRule],
        profiles: [FanProfile],
        temperatures: [String: Double],
        states: Set<MacState>,
        fanCount: Int,
        at date: Date
    ) -> FanProfile? {
        var fastest: FanProfile?
        applyingRules = []
        for rule in rules where applies(rule, temperatures: temperatures, states: states, at: date) {
            applyingRules.insert(rule.id)
            guard let profile = profiles.first(where: { $0.id == rule.profile }) else { continue }
            if profile.totalSpeed(fanCount: fanCount) > fastest?.totalSpeed(fanCount: fanCount) ?? -1 {
                fastest = profile
            }
        }
        lastHot = lastHot.filter { id, _ in rules.contains { $0.id == id } }
        return fastest
    }

    private mutating func applies(_ rule: FanRule, temperatures: [String: Double], states: Set<MacState>, at date: Date) -> Bool {
        guard rule.alsoWhen.map(states.contains) ?? true else {
            lastHot[rule.id] = nil
            return false
        }
        let reading: Double?
        switch rule.trigger {
        case .state(let state):
            return states.contains(state)
        case .anySensor:
            reading = temperatures.values.max()
        case .sensor(let sensor):
            reading = temperatures[sensor]
        }
        let wasOn = lastHot[rule.id] != nil
        if let reading, reading > rule.temperature - (wasOn ? Self.coolingMargin : 0) {
            lastHot[rule.id] = date
            return true
        }
        guard let last = lastHot[rule.id], date.timeIntervalSince(last) < Self.holdTime else {
            lastHot[rule.id] = nil
            return false
        }
        return true
    }
}
