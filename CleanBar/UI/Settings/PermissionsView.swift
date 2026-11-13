import SwiftUI

struct PermissionsView: View {
    let permissions: PermissionStatus

    var body: some View {
        Form {
            Section {
                PaneHeader(
                    tab: .permissions,
                    description: "CleanBar needs two permissions to work. Press the Allow button next to each permission to open System Settings, then drag CleanBar's icon into the list to grant it."
                )
            }

            if let conflictingApp = permissions.conflictingAppName {
                Section {
                    Notice(text: String(localized: "\(conflictingApp) is running. Quit it before using CleanBar, or the two apps will keep moving each other's items."))
                }
            }

            Section {
                PermissionRow(
                    title: "Accessibility",
                    symbol: "accessibility",
                    tint: .blue,
                    explanation: "Lets CleanBar see your menu bar icons, move them for you and open Notification Center when you click the clock while icons are hidden.",
                    isGranted: permissions.accessibility,
                    action: { Permissions.request(.accessibility) }
                )
                PermissionRow(
                    title: "Screen Recording",
                    symbol: "rectangle.dashed.badge.record",
                    tint: .red,
                    explanation: "Lets CleanBar take pictures of your menu bar icons for the layout editor. Nothing is recorded or saved.",
                    isGranted: permissions.screenRecording,
                    action: { Permissions.request(.screenRecording) }
                )
            } footer: {
                if permissions.missingCount > 0 {
                    HStack(alignment: .firstTextBaseline) {
                        Text("If a permission is on in System Settings but still missing here, reset it. CleanBar removes it from System Settings and restarts, then you allow it again.")
                        Spacer()
                        Button("Reset Permissions", action: Permissions.resetAndRelaunch)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(SettingsTab.permissions.title)
    }
}

private struct PermissionRow: View {
    let title: LocalizedStringKey
    let symbol: String
    let tint: Color
    let explanation: LocalizedStringKey
    let isGranted: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            SymbolBadge(symbol: symbol, tint: tint, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(explanation)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if isGranted {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Allowed")
                        .foregroundStyle(.secondary)
                }
            } else {
                Button("Allow", action: action)
            }
        }
        .padding(.vertical, 2)
    }
}
