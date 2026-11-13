import AppKit
import SwiftUI

struct SensorsView: View {
    @Bindable var settings: AppSettings
    let sensors: SensorsController

    @State private var clickMonitor: Any?

    private var monitor: SensorMonitor { sensors.monitor }

    var body: some View {
        Form {
            Section {
                PaneHeader(
                    tab: .sensors,
                    description: "See your Mac's temperature in the menu bar. Click it for every sensor and fan, rest the pointer on one for its history, and on Fans to set their speed."
                )
            }

            Section {
                Toggle("Show the temperature in the menu bar", isOn: $settings.showsSensors)
            }

            if settings.showsSensors {
                MenuBarIconSection(settings: settings, sensors: sensors)
                SensorListSection(settings: settings, monitor: monitor)
                if !monitor.fans.isEmpty {
                    FanControlSection(settings: settings, fans: sensors.fans)
                    FanRulesSection(settings: settings, monitor: monitor, fans: sensors.fans)
                    FanProfilesSection(settings: settings, monitor: monitor, fans: sensors.fans)
                    FanHelperSection(fans: sensors.fans)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(SettingsTab.sensors.title)
        .onAppear {
            sensors.isPaneShowing = true
            clickMonitor = Self.endTypingOnClicksElsewhere()
        }
        .onDisappear {
            sensors.isPaneShowing = false
            clickMonitor.map(NSEvent.removeMonitor)
            clickMonitor = nil
        }
    }

    /// Clicking a part of the page that doesn't take the keyboard, or anything else outside the field being typed in, ends the
    /// typing. By itself a text field keeps the focus until something else asks for it.
    private static func endTypingOnClicksElsewhere() -> Any? {
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            MainActor.assumeIsolated {
                if let window = event.window, let editor = window.firstResponder as? NSText, let field = editor.delegate as? NSView,
                   !field.bounds.contains(field.convert(event.locationInWindow, from: nil)) {
                    window.makeFirstResponder(nil)
                }
            }
            return event
        }
    }
}

// MARK: The menu bar icon

private struct MenuBarIconSection: View {
    @Bindable var settings: AppSettings
    let sensors: SensorsController

    var body: some View {
        Section {
            Picker("Shows", selection: $settings.menuBarSensor) {
                Text("Icon Only").tag(TemperatureSensor.noneID)
                Divider()
                ForEach(sensors.monitor.sensors) { sensor in
                    Text(sensor.name).tag(sensor.id)
                }
            }
            SensorColorRow(color: $settings.sensorIconColor)
            LabeledContent("Size") {
                Slider(value: $settings.sensorIconSize, in: AppSettings.sensorIconSizes, step: 1) {
                    Text("Size")
                } minimumValueLabel: {
                    Image(systemName: "textformat.size.smaller")
                } maximumValueLabel: {
                    Image(systemName: "textformat.size.larger")
                }
                .labelsHidden()
                .frame(maxWidth: 240)
            }
        } header: {
            Text("Menu Bar Icon")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                if settings.menuBarSensor == TemperatureSensor.noneID {
                    Text("With only an icon, CleanBar reads the sensors every 30 seconds instead of every 5, to save CPU. Rules and the sensors list still get them as often as they need.")
                }
                Text("If you can't see the temperature, it's behind Apple's «: move it under Menu Bar Layout, or hold ⌘ and drag it.")
            }
        }
    }
}

/// The icon's color, the way System Settings has you pick an accent color: same as the menu bar, a few to pick from, or any
/// other in the color well.
private struct SensorColorRow: View {
    @Binding var color: NSColor?

    private struct Swatch: Identifiable {
        let name: String
        let color: NSColor

        var id: String { name }

        init(_ name: String, _ red: Double, _ green: Double, _ blue: Double) {
            self.name = name
            color = NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
        }
    }

    /// Bright enough for a menu bar of any color. Fixed rather than `NSColor.systemRed` and so on: what's saved is the color
    /// itself, and those come to something else in dark mode, so it wouldn't match its swatch anymore after switching.
    private static var swatches: [Swatch] {
        [
            Swatch(String(localized: "Red"), 1, 0.27, 0.23),
            Swatch(String(localized: "Orange"), 1, 0.62, 0.04),
            Swatch(String(localized: "Yellow"), 1, 0.84, 0.04),
            Swatch(String(localized: "Green"), 0.19, 0.82, 0.35),
            Swatch(String(localized: "Blue"), 0.04, 0.52, 1),
            Swatch(String(localized: "Purple"), 0.75, 0.35, 0.95),
            Swatch(String(localized: "Pink"), 1, 0.22, 0.37),
        ]
    }

    private var selectedSwatch: Swatch? {
        guard let color = color?.usingColorSpace(.sRGB) else { return nil }
        return Self.swatches.first { swatch in
            guard let other = swatch.color.usingColorSpace(.sRGB) else { return false }
            return abs(color.redComponent - other.redComponent) < 0.01
                && abs(color.greenComponent - other.greenComponent) < 0.01
                && abs(color.blueComponent - other.blueComponent) < 0.01
        }
    }

    private var colorName: String {
        if color == nil {
            return String(localized: "Same as the Menu Bar")
        }
        return selectedSwatch?.name ?? String(localized: "Custom")
    }

    var body: some View {
        LabeledContent {
            HStack(spacing: 4) {
                ColorSwatch(
                    name: String(localized: "Same as the Menu Bar"),
                    // Dark or light, depending on what's behind the menu bar.
                    fill: LinearGradient(
                        stops: [.init(color: .white, location: 0.5), .init(color: .black, location: 0.5)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    isSelected: color == nil
                ) {
                    color = nil
                }
                ForEach(Self.swatches) { swatch in
                    ColorSwatch(name: swatch.name, fill: Color(nsColor: swatch.color), isSelected: swatch.id == selectedSwatch?.id) {
                        color = swatch.color
                    }
                }
                ColorPicker(String(localized: "Custom"), selection: customColor, supportsOpacity: false)
                    .labelsHidden()
                    .controlSize(.small)
                    .padding(.leading, 6)
                    .help(String(localized: "Custom"))
            }
        } label: {
            Text("Color")
            Text(colorName)
        }
    }

    private var customColor: Binding<Color> {
        Binding {
            color.map(Color.init(nsColor:)) ?? .orange
        } set: { color in
            self.color = NSColor(color)
        }
    }
}

private struct ColorSwatch<Fill: ShapeStyle>: View {
    let name: String
    let fill: Fill
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(fill)
                .overlay {
                    Circle().strokeBorder(.primary.opacity(0.2), lineWidth: 0.5)
                }
                .frame(width: 16, height: 16)
                .padding(3)
                .overlay {
                    if isSelected {
                        Circle().strokeBorder(Color.accentColor, lineWidth: 2)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel(name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: Who controls the fans

/// Who decides how fast the fans turn now, and when CleanBar opens.
private struct FanControlSection: View {
    @Bindable var settings: AppSettings
    let fans: FanController

    var body: some View {
        Section {
            LabeledContent("Right Now") {
                Text(fans.summary)
                    .monospacedDigit()
            }
            Picker("When CleanBar Opens", selection: defaultMode) {
                Text("Automatic").tag(FanMode.automatic)
                Text("System Controlled").tag(FanMode.system)
                Divider()
                ForEach(settings.fanProfiles) { profile in
                    Text(profile.name).tag(FanMode.profile(profile.id))
                }
            }
            if let problem = fans.problem {
                Notice(text: problem)
            }
        } header: {
            Text("Fans")
        } footer: {
            Text("Automatic follows the rules below. To change what the fans do just for now, click the temperature in the menu bar.")
        }
    }

    /// Picking it also goes by it right away.
    private var defaultMode: Binding<FanMode> {
        Binding {
            settings.fanDefaultMode
        } set: { mode in
            settings.fanDefaultMode = mode
            fans.select(mode)
        }
    }
}

private struct FanHelperSection: View {
    let fans: FanController

    var body: some View {
        Section {
            // By hand, as `LabeledContent` keeps what's on the right at the top of a row this tall.
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Fan Helper")
                    Text("Only administrators can change the fans, so CleanBar uses a small helper for it. It's installed with your password the first time you change them, and runs only while you've set a speed. When CleanBar quits, macOS takes over the fans again.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if fans.isHelperInstalled {
                    Button("Remove Helper…") { fans.removeHelper() }
                } else {
                    Text("Not Installed")
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
        }
    }
}
