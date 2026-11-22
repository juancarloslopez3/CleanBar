import AppKit
import SwiftUI

/// The rules the fans follow on Automatic.
struct FanRulesSection: View {
    @Bindable var settings: AppSettings
    let monitor: SensorMonitor
    let fans: FanController
    /// How wide the rows are, which they need to agree on for their columns to line up.
    @State private var rowWidth: CGFloat = 0

    var body: some View {
        Section {
            if settings.fanRules.isEmpty {
                HStack {
                    Text("No rules yet, so macOS controls the fans on Automatic.")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button("Add Rule", action: addRule)
                }
            } else {
                FanRuleColumns(rowWidth: rowWidth, onAdd: addRule)
                    .onGeometryChange(for: CGFloat.self, of: \.size.width) { rowWidth = $0 }
                ForEach(settings.fanRules) { rule in
                    FanRuleRow(
                        rule: binding(for: rule),
                        isApplying: fans.applyingRules.contains(rule.id),
                        otherRules: settings.fanRules.filter { $0.id != rule.id },
                        profiles: settings.fanProfiles,
                        sensors: monitor.sensors,
                        rowWidth: rowWidth
                    ) {
                        settings.fanRules.removeAll { $0.id == rule.id }
                        fans.setupChanged()
                    }
                }
                if fans.isHeldByAnotherApp {
                    Notice(
                        text: String(localized: "Another app is setting the speed of the fans. Turn that off in that app for CleanBar to take over."),
                        kind: .info
                    )
                } else if fans.mode != .automatic {
                    Notice(
                        text: String(localized: "The fans are set to “\(fans.summary)” for now, so the rules are waiting."),
                        kind: .info,
                        buttonTitle: String(localized: "Follow Rules")
                    ) {
                        fans.select(.automatic)
                    }
                }
            }
            if fans.needsHelper {
                Notice(
                    text: String(localized: "The rules can't change the fans until CleanBar's fan helper is installed, which takes your password."),
                    buttonTitle: String(localized: "Install Helper…")
                ) {
                    fans.installHelper()
                }
            }
        } header: {
            Text("Automatic Rules")
        } footer: {
            Text("When several rules apply, the fans use the fastest of their profiles. When none does, macOS controls them. A rule on a temperature stays on until it has been a few degrees lower for 30 seconds, so the fans don't keep changing speed. A rule can't ask for things that don't go together, or for exactly what another rule asks for, so those choices are dimmed.")
        }
    }

    private func binding(for rule: FanRule) -> Binding<FanRule> {
        Binding {
            settings.fanRules.first { $0.id == rule.id } ?? rule
        } set: { changed in
            guard let index = settings.fanRules.firstIndex(where: { $0.id == rule.id }) else { return }
            // A sensor or state just picked can land on what another rule has at this temperature, which the menus don't dim, as
            // the temperature isn't always showing to say why.
            settings.fanRules[index] = changed.clear(of: settings.fanRules.filter { $0.id != rule.id })
            fans.setupChanged()
        }
    }

    /// Something that doesn't get in the way until the user sets it up: the second fastest speed when it's getting hot.
    private func addRule() {
        let profile = FanProfile.defaults[FanProfile.defaults.count - 2]
        settings.fanRules.append(FanRule(profile: profile.id, temperature: 80).clear(of: settings.fanRules))
        fans.setupChanged()
    }
}

/// How wide the parts of a rule's row are, for its columns to line up with those of the other rules and the titles above them.
private enum FanRuleLayout {
    static let spacing: CGFloat = 6
    static let statusWidth: CGFloat = 8
    static let profileWidth: CGFloat = 96
    static let triggerMinWidth: CGFloat = 120
    static let buttonWidth: CGFloat = 20
    /// Where a popup's title starts, inside its frame.
    static let popupTitleInset: CGFloat = 12

    /// Less room for the state when the window is at its narrowest. Before the rows are measured it doesn't matter.
    static func stateWidth(rowWidth: CGFloat) -> CGFloat {
        rowWidth > 0 && rowWidth < 540 ? 120 : 150
    }
}

/// What each column of the rules is, with the button that adds one above those that remove them.
private struct FanRuleColumns: View {
    let rowWidth: CGFloat
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: FanRuleLayout.spacing) {
            Color.clear
                .frame(width: FanRuleLayout.statusWidth, height: 1)
            Text("Profile")
                .padding(.leading, FanRuleLayout.popupTitleInset)
                .frame(width: FanRuleLayout.profileWidth, alignment: .leading)
            Text("When")
                .padding(.leading, FanRuleLayout.popupTitleInset)
                .frame(minWidth: FanRuleLayout.triggerMinWidth, maxWidth: .infinity, alignment: .leading)
            Text("Also When")
                .lineLimit(1)
                .padding(.leading, FanRuleLayout.popupTitleInset)
                .frame(width: FanRuleLayout.stateWidth(rowWidth: rowWidth), alignment: .leading)
            Button("Add Rule", systemImage: "plus.circle.fill", action: onAdd)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .font(.body)
                .foregroundStyle(.tint)
                .frame(width: FanRuleLayout.buttonWidth)
                .help(String(localized: "Add Rule"))
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
}

/// Runs the fans at a profile when something's so, like when any sensor is over 55°C, and maybe something else as well.
private struct FanRuleRow: View {
    @Binding var rule: FanRule
    /// Whether its conditions are met now.
    let isApplying: Bool
    /// What it can't repeat.
    let otherRules: [FanRule]
    let profiles: [FanProfile]
    let sensors: [TemperatureSensor]
    let rowWidth: CGFloat
    let onRemove: () -> Void

    private typealias TriggerItem = ColumnPicker<FanRule.Trigger>.Item
    private typealias StateItem = ColumnPicker<MacState?>.Item

    private var profileName: String {
        profiles.first { $0.id == rule.profile }?.name ?? ""
    }

    private var triggerName: String {
        switch rule.trigger {
        case .anySensor: String(localized: "Any Sensor")
        case .sensor(let id): sensors.first { $0.id == id }?.name ?? id
        case .state(let state): state.title
        }
    }

    private var stateName: String {
        rule.alsoWhen?.title ?? String(localized: "Any State")
    }

    /// What the Mac can be up to, then the sensors. A sensor that isn't there right now, or a state this Mac doesn't have,
    /// is kept at the end for a rule that goes by it.
    private var triggerItems: [TriggerItem] {
        var items = MacState.available.map { TriggerItem(title: $0.title, value: .state($0), isEnabled: allows(trigger: .state($0)), help: $0.help) }
        items.append(TriggerItem(title: String(localized: "Any Sensor"), value: .anySensor))
        items.append(TriggerItem(title: "", value: nil))
        items += sensors.map { TriggerItem(title: $0.name, value: .sensor($0.id)) }
        if !items.contains(where: { $0.value == rule.trigger }) {
            items.append(TriggerItem(title: triggerName, value: rule.trigger))
        }
        return items
    }

    private var stateItems: [StateItem] {
        var items = [
            StateItem(title: String(localized: "Any State"), value: .some(nil), isEnabled: allows(alsoWhen: nil)),
            StateItem(title: "", value: nil),
        ]
        items += MacState.available.map { StateItem(title: $0.title, value: $0, isEnabled: allows(alsoWhen: $0), help: $0.help) }
        if let state = rule.alsoWhen, !MacState.available.contains(state) {
            items.append(StateItem(title: state.title, value: state))
        }
        return items
    }

    private func allows(trigger: FanRule.Trigger) -> Bool {
        var changed = rule
        changed.trigger = trigger
        return changed.isAllowed(among: otherRules)
    }

    private func allows(alsoWhen: MacState?) -> Bool {
        var changed = rule
        changed.alsoWhen = alsoWhen
        return changed.isAllowed(among: otherRules)
    }

    /// Whether another rule with the same conditions goes by that temperature.
    private func isTaken(celsius: Double) -> Bool {
        var changed = rule
        changed.temperature = celsius
        return otherRules.contains(where: changed.hasSameConditions)
    }

    private var statusText: String {
        isApplying ? String(localized: "This rule applies now") : String(localized: "This rule doesn't apply now")
    }

    var body: some View {
        HStack(spacing: FanRuleLayout.spacing) {
            Circle()
                .fill(isApplying ? AnyShapeStyle(.green) : AnyShapeStyle(.quaternary))
                .frame(width: FanRuleLayout.statusWidth, height: FanRuleLayout.statusWidth)
                .help(statusText)
                .accessibilityLabel(statusText)

            ColumnPicker(
                label: String(localized: "Profile"),
                items: profiles.map { .init(title: $0.name, value: $0.id) },
                selection: $rule.profile
            )
            .frame(width: FanRuleLayout.profileWidth)
            .help(profileName)

            ColumnPicker(label: String(localized: "When"), items: triggerItems, selection: $rule.trigger)
                .frame(minWidth: FanRuleLayout.triggerMinWidth, maxWidth: .infinity)
                .help(triggerName)

            if rule.trigger.goesByTemperature {
                Text("is >")
                    .foregroundStyle(.secondary)
                    .fixedSize()
                TemperatureField(celsius: $rule.temperature, isTaken: isTaken)
            }

            ColumnPicker(label: String(localized: "Also When"), items: stateItems, selection: $rule.alsoWhen)
                .frame(width: FanRuleLayout.stateWidth(rowWidth: rowWidth))
                .help(stateName)

            Button("Remove Rule", systemImage: "minus.circle.fill", action: onRemove)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .frame(width: FanRuleLayout.buttonWidth)
                .help(String(localized: "Remove Rule"))
        }
    }
}

/// A popup with its title at the left of the width it's given and its arrows at the right, so those above each other line up
/// in a column. SwiftUI's `Picker` centers all that in a `Form`, whatever its style (seen on macOS 27).
private struct ColumnPicker<Value: Hashable>: NSViewRepresentable {
    /// A choice, or a line between choices when `value` is nil.
    struct Item: Equatable {
        let title: String
        let value: Value?
        /// Whether it can be picked. It stays in the list when not, so the choices don't move around.
        var isEnabled = true
        /// A tooltip explaining the choice.
        var help: String?
    }

    let label: String
    let items: [Item]
    @Binding var selection: Value

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSPopUpButton {
        let popup = NSPopUpButton()
        popup.target = context.coordinator
        popup.action = #selector(Coordinator.picked(_:))
        popup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        popup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        popup.setAccessibilityLabel(label)
        return popup
    }

    func updateNSView(_ popup: NSPopUpButton, context: Context) {
        let wereShown = context.coordinator.parent.items == items && popup.numberOfItems > 0
        context.coordinator.parent = self
        if !wereShown {
            // Into the menu rather than through the popup, which drops all but one of the items with the same name.
            let menu = NSMenu()
            menu.autoenablesItems = false
            for item in items {
                let menuItem = item.value == nil ? NSMenuItem.separator() : NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
                menuItem.isEnabled = item.isEnabled
                menuItem.toolTip = item.help
                menu.addItem(menuItem)
            }
            popup.menu = menu
            popup.autoenablesItems = false
        }
        popup.selectItem(at: items.firstIndex { $0.value == selection } ?? -1)
    }

    final class Coordinator: NSObject {
        var parent: ColumnPicker

        init(parent: ColumnPicker) {
            self.parent = parent
        }

        @objc func picked(_ popup: NSPopUpButton) {
            let index = popup.indexOfSelectedItem
            if parent.items.indices.contains(index), let value = parent.items[index].value {
                parent.selection = value
            }
        }
    }
}

/// A temperature to type, in the Mac's unit. It's kept in °C, within what makes sense for a rule, and counts once it's done:
/// Return, or leaving the field. One that's taken gets a beep and the field goes back. Esc goes back as well.
private struct TemperatureField: View {
    @Binding var celsius: Double
    /// Whether it can't be that temperature, in °C.
    let isTaken: (Double) -> Bool

    /// What's in the field while typing. Otherwise it shows the temperature.
    @State private var typed: String?
    @FocusState private var isFocused: Bool

    private var shown: String {
        String(Int(TemperatureText.degrees(celsius).rounded()))
    }

    private var text: Binding<String> {
        Binding {
            typed ?? shown
        } set: { text in
            if text != typed ?? shown {
                typed = text
            }
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            TextField("Temperature", text: text)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 38)
                .focused($isFocused)
                .onSubmit {
                    commit()
                    isFocused = false
                }
                .onExitCommand {
                    typed = nil
                    isFocused = false
                }
            Text(verbatim: TemperatureText.unit)
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        // Here rather than in the binding: a text field keeps showing what was typed if its state ends up just as it was.
        .onChange(of: typed) {
            if let typed, typed.contains(where: { !$0.isASCII || !$0.isNumber }) {
                self.typed = typed.filter { $0.isASCII && $0.isNumber }
            }
        }
        .onChange(of: isFocused) {
            if !isFocused {
                commit()
            }
        }
        .onDisappear(perform: commit)
    }

    private func commit() {
        guard let typed else { return }
        self.typed = nil
        guard let degrees = Double(typed), degrees != TemperatureText.degrees(celsius).rounded() else { return }
        let limits = FanRule.temperatures
        let wanted = min(max(TemperatureText.celsius(fromDegrees: degrees), limits.lowerBound), limits.upperBound)
        if isTaken(wanted) {
            NSSound.beep()
        } else {
            celsius = wanted
        }
    }
}
