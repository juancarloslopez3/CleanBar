import AppKit
import SwiftUI

/// The speeds to pick from when resting the pointer on Fans in the sensors list. The ones CleanBar comes with stay as they
/// are, as their name says what they do.
struct FanProfilesSection: View {
    @Bindable var settings: AppSettings
    let monitor: SensorMonitor
    let fans: FanController
    @State private var selection: FanProfile.ID?
    @State private var renaming: FanProfile.ID?
    /// The profile to ask about before deleting it, because rules use it.
    @State private var deleting: FanProfile?

    /// Room for all the fans and a note of two lines, or else for six profiles, so it's the same for every profile.
    private var height: CGFloat { max(196, CGFloat(monitor.fans.count) * 70 + 56) }

    private var selectedProfile: FanProfile? {
        settings.fanProfiles.first { $0.id == selection }
    }

    var body: some View {
        Section {
            HStack(spacing: 0) {
                profileList
                    .frame(width: 150)
                Divider()
                if let selectedProfile {
                    profileDetail(selectedProfile)
                }
            }
            .fillingFormRow(height: height)
            .onAppear {
                selection = selection ?? settings.fanProfiles.first?.id
            }
        } header: {
            Text("Fan Profiles")
        } footer: {
            Text("Double-click a profile you added to rename it. macOS still protects your Mac if it gets too hot.")
        }
        .confirmationDialog(
            String(localized: "Delete “\(deleting?.name ?? "")”?"),
            isPresented: Binding { deleting != nil } set: { if !$0 { deleting = nil } },
            presenting: deleting
        ) { profile in
            Button("Delete Profile and Its Rules", role: .destructive) { delete(profile) }
        } message: { _ in
            Text("Rules use this profile, so they'd be deleted with it.")
        }
    }

    /// With its buttons in a bar at the bottom, as lists have them in System Settings.
    private var profileList: some View {
        VStack(spacing: 0) {
            FanProfileTable(
                profiles: settings.fanProfiles,
                selection: $selection,
                renaming: $renaming,
                onRename: rename,
                onDelete: askToDelete
            )
            Divider()
            HStack(spacing: 0) {
                ProfileBarButton(title: "Add Profile", symbol: "plus", action: addProfile)
                ProfileBarButton(title: "Remove Profile", symbol: "minus") {
                    if let selectedProfile { askToDelete(selectedProfile.id) }
                }
                .disabled(selectedProfile?.isDefault != false)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
        }
    }

    private func profileDetail(_ profile: FanProfile) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(monitor.fans) { fan in
                FanSpeedEditor(fan: fan, speed: speed(of: fan, in: profile), isLocked: profile.isDefault) {
                    fans.setupChanged()
                }
            }
            if profile.isDefault {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Image(systemName: "lock.fill")
                        .imageScale(.small)
                        .accessibilityHidden(true)
                    Text("This profile always stays as it is. Add your own to choose each fan's speed.")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
    }

    private func speed(of fan: FanReading, in profile: FanProfile) -> Binding<Double> {
        Binding {
            profile.speed(ofFan: fan.index)
        } set: { speed in
            guard let index = settings.customFanProfiles.firstIndex(where: { $0.id == profile.id }) else { return }
            settings.customFanProfiles[index].setSpeed(speed, ofFan: fan.index, fanCount: monitor.fans.count)
        }
    }

    /// Starts with the name selected to type over, as with a new folder in the Finder.
    private func addProfile() {
        let profile = FanProfile(
            name: FanProfile.unusedName(among: settings.fanProfiles),
            speeds: Array(repeating: 50, count: max(monitor.fans.count, 1))
        )
        settings.customFanProfiles.append(profile)
        selection = profile.id
        renaming = profile.id
    }

    private func rename(_ id: FanProfile.ID, to name: String) {
        guard let index = settings.customFanProfiles.firstIndex(where: { $0.id == id }) else { return }
        settings.customFanProfiles[index].name = name
        fans.setupChanged()
    }

    private func askToDelete(_ id: FanProfile.ID) {
        guard let profile = settings.customFanProfiles.first(where: { $0.id == id }) else { return }
        if settings.fanRules.contains(where: { $0.profile == id }) {
            deleting = profile
        } else {
            delete(profile)
        }
    }

    private func delete(_ profile: FanProfile) {
        let all = settings.fanProfiles
        settings.fanRules.removeAll { $0.profile == profile.id }
        settings.customFanProfiles.removeAll { $0.id == profile.id }
        if settings.fanDefaultMode == .profile(profile.id) {
            settings.fanDefaultMode = .automatic
        }
        if selection == profile.id, let index = all.firstIndex(of: profile) {
            // The one that takes its place in the list, or the last one when it was that.
            let remaining = settings.fanProfiles
            selection = remaining[min(index, remaining.count - 1)].id
        }
        fans.setupChanged()
    }
}

/// A button in the bar under the list of profiles, which counts all the way out to the bar's edges and the next button, not
/// only on its symbol.
private struct ProfileBarButton: View {
    let title: LocalizedStringKey
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .labelStyle(.iconOnly)
                .frame(width: 34, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
    }
}

/// The list of profiles. One of AppKit's tables for the same reason as `SensorOrderTable`, and because it can rename a row in
/// place, with Return as in the Finder.
private struct FanProfileTable: NSViewRepresentable {
    let profiles: [FanProfile]
    @Binding var selection: FanProfile.ID?
    /// Set to start renaming a profile, as soon as it's in the list.
    @Binding var renaming: FanProfile.ID?
    let onRename: (FanProfile.ID, String) -> Void
    let onDelete: (FanProfile.ID) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let table = FanProfileTableView()
        table.addTableColumn(NSTableColumn(identifier: Coordinator.cellID))
        table.headerView = nil
        table.style = .inset
        table.backgroundColor = .clear
        table.allowsEmptySelection = false
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked)
        table.onReturn = { [weak coordinator = context.coordinator] in coordinator?.renameSelection() }
        let menu = NSMenu()
        menu.delegate = context.coordinator
        table.menu = menu
        context.coordinator.table = table
        return NSScrollView.holding(table)
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        let didChange = coordinator.parent.profiles != profiles
        coordinator.parent = self
        guard let table = scrollView.documentView as? NSTableView else { return }
        // Not while a name is being typed in it, which reloading would end.
        if didChange, table.currentEditor() == nil {
            table.reloadData()
        }
        if let row = profiles.firstIndex(where: { $0.id == selection }), table.selectedRow != row {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
        }
        if let renaming {
            // Not during the update, which is setting what's in the table.
            DispatchQueue.main.async {
                self.renaming = nil
                coordinator.rename(renaming)
            }
        }
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSMenuDelegate {
        static let cellID = NSUserInterfaceItemIdentifier("profile")
        var parent: FanProfileTable
        weak var table: NSTableView?
        /// The profile whose name is being typed.
        private var renamingID: FanProfile.ID?

        init(parent: FanProfileTable) {
            self.parent = parent
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            parent.profiles.count
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let cell = tableView.makeView(withIdentifier: Self.cellID, owner: self) as? NSTableCellView ?? makeCell()
            cell.textField?.stringValue = parent.profiles[row].name
            return cell
        }

        private func makeCell() -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = Self.cellID
            let field = NSTextField(labelWithString: "")
            field.delegate = self
            field.lineBreakMode = .byTruncatingTail
            field.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(field)
            cell.textField = field
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let table, parent.profiles.indices.contains(table.selectedRow) else { return }
            parent.selection = parent.profiles[table.selectedRow].id
        }

        // MARK: Renaming

        func renameSelection() {
            guard let table, parent.profiles.indices.contains(table.selectedRow) else { return }
            rename(parent.profiles[table.selectedRow].id)
        }

        @objc func doubleClicked() {
            guard let table, parent.profiles.indices.contains(table.clickedRow) else { return }
            rename(parent.profiles[table.clickedRow].id)
        }

        func rename(_ id: FanProfile.ID) {
            guard let table, let row = parent.profiles.firstIndex(where: { $0.id == id }), !parent.profiles[row].isDefault,
                  let field = (table.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView)?.textField
            else { return }
            renamingID = id
            field.isEditable = true
            // Selects the name to type over.
            table.window?.makeFirstResponder(field)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField, let id = renamingID else { return }
            renamingID = nil
            field.isEditable = false
            let oldName = parent.profiles.first { $0.id == id }?.name ?? ""
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty {
                field.stringValue = oldName
            } else if name != oldName {
                parent.onRename(id, name)
            }
            // Otherwise it ended because something else was clicked, which keeps the keyboard.
            if notification.userInfo?["NSTextMovement"] as? Int == NSTextMovement.return.rawValue {
                table?.window?.makeFirstResponder(table)
            }
        }

        /// Esc keeps the name it had.
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.cancelOperation(_:)), let id = renamingID else { return false }
            textView.string = parent.profiles.first { $0.id == id }?.name ?? ""
            control.window?.makeFirstResponder(table)
            return true
        }

        // MARK: Right-clicking

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let table, parent.profiles.indices.contains(table.clickedRow) else { return }
            let profile = parent.profiles[table.clickedRow]
            for (title, action) in [
                (String(localized: "Rename"), #selector(renameClicked(_:))),
                (String(localized: "Delete"), #selector(deleteClicked(_:))),
            ] {
                let item = menu.addItem(withTitle: title, action: profile.isDefault ? nil : action, keyEquivalent: "")
                item.target = self
                item.representedObject = profile.id
            }
        }

        @objc private func renameClicked(_ item: NSMenuItem) {
            if let id = item.representedObject as? UUID {
                parent.selection = id
                // Once the menu has gone, which takes the field's focus with it.
                DispatchQueue.main.async { self.rename(id) }
            }
        }

        @objc private func deleteClicked(_ item: NSMenuItem) {
            if let id = item.representedObject as? UUID {
                parent.onDelete(id)
            }
        }
    }
}

private final class FanProfileTableView: NSTableView {
    var onReturn: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        // Return, and Enter on a numeric keypad.
        if event.keyCode == 36 || event.keyCode == 76 {
            onReturn?()
        } else {
            super.keyDown(with: event)
        }
    }
}

/// A fan's speed in a profile, with what that comes to in rpm, and how slow and fast the fan can go.
private struct FanSpeedEditor: View {
    let fan: FanReading
    @Binding var speed: Double
    /// Whether it's only there to show the speed.
    let isLocked: Bool
    /// Called when the slider is let go or typing is done, so the fans aren't told about each step on the way.
    let onCommit: () -> Void

    var body: some View {
        VStack(spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(fan.name)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text("\(Int(fan.rpm(forPercent: speed))) rpm")
                    .foregroundStyle(.secondary)
                if isLocked {
                    Text(verbatim: "\(Int(speed.rounded()))%")
                        .fontWeight(.medium)
                        .frame(minWidth: 36, alignment: .trailing)
                } else {
                    PercentField(label: fan.name, percent: $speed, onCommit: onCommit)
                }
            }
            .monospacedDigit()
            Group {
                if isLocked {
                    SpeedBar(percent: speed)
                        .accessibilityLabel(fan.name)
                        .accessibilityValue(Text(verbatim: "\(Int(speed.rounded()))%"))
                } else {
                    // In whole percents, without the tick marks that asking for steps of 1 would draw.
                    Slider(value: Binding { speed } set: { speed = $0.rounded() }, in: 0...100) {
                        Text(fan.name)
                    } onEditingChanged: { isEditing in
                        if !isEditing {
                            onCommit()
                        }
                    }
                    .labelsHidden()
                }
            }
            .frame(height: 22)
            HStack {
                Text("\(Int(fan.minimum.rounded())) rpm")
                Spacer(minLength: 8)
                Text("\(Int(fan.maximum.rounded())) rpm")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
    }
}

/// A percentage to type, from 0 to 100. It counts as it's typed, so the slider and the rpm go along with it, and only the fans
/// wait until it's done: Return, or leaving the field, both of which take the focus from it. Esc goes back to what it was.
private struct PercentField: View {
    let label: String
    @Binding var percent: Double
    let onCommit: () -> Void

    /// What's in the field while typing. Otherwise it shows the percentage.
    @State private var typed: String?
    /// What Esc goes back to.
    @State private var percentBeforeTyping: Double?
    @FocusState private var isFocused: Bool

    private var text: Binding<String> {
        Binding {
            typed ?? String(Int(percent.rounded()))
        } set: { text in
            guard text != typed ?? String(Int(percent.rounded())) else { return }
            if typed == nil {
                percentBeforeTyping = percent
            }
            typed = text
        }
    }

    var body: some View {
        HStack(spacing: 2) {
            TextField(label, text: text)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 40)
                .focused($isFocused)
                .onSubmit {
                    commit()
                    isFocused = false
                }
                .onExitCommand(perform: cancel)
            Text(verbatim: "%")
                .foregroundStyle(.secondary)
        }
        // Here rather than in the binding: a text field keeps showing what was typed if its state ends up just as it was.
        .onChange(of: typed) { apply() }
        .onChange(of: percent) {
            // The slider moved, or it's another profile's now.
            if let typed, Int(typed) != Int(percent.rounded()) {
                commit()
            }
        }
        .onChange(of: isFocused) {
            if !isFocused {
                commit()
            }
        }
        .onDisappear(perform: commit)
    }

    /// Only takes digits, and over 100 is 100.
    private func apply() {
        guard let typed else { return }
        var digits = String(typed.filter { $0.isASCII && $0.isNumber }.prefix(3))
        if let value = Int(digits) {
            if value > 100 {
                digits = "100"
            }
            percent = Double(min(value, 100))
        }
        if digits != typed {
            self.typed = digits
        }
    }

    private func commit() {
        guard typed != nil else { return }
        typed = nil
        onCommit()
    }

    private func cancel() {
        if typed != nil, let percentBeforeTyping {
            percent = percentBeforeTyping
        }
        typed = nil
        isFocused = false
    }
}

/// A speed that can't be changed. Plainly not a control: a disabled slider looks just like one that isn't (seen on macOS 27),
/// and a faded one looks broken.
private struct SpeedBar: View {
    let percent: Double

    private static let height: CGFloat = 6

    var body: some View {
        Capsule()
            .fill(.quaternary)
            .frame(height: Self.height)
            .overlay {
                GeometryReader { geometry in
                    Capsule()
                        .fill(.secondary)
                        .frame(width: max(geometry.size.width * percent / 100, Self.height))
                }
            }
            .accessibilityElement()
    }
}
