import SwiftUI

struct GeneralView: View {
    @Bindable var settings: AppSettings
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchAtLoginError: String?
    /// What's typed in the "Hide after" field, saved when it's submitted or loses focus.
    @State private var delayText = ""
    @FocusState private var isEditingDelay: Bool

    private var isFloatingBar: Bool { settings.hiddenIconsStyle == .floatingBar }

    var body: some View {
        Form {
            Section {
                PaneHeader(
                    tab: .general,
                    description: "Choose whether CleanBar opens at login, its language and appearance, its icon, how hidden icons show and when they go away again, and the shortcut that shows them."
                )
            }

            Section {
                Toggle("Open CleanBar at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        setLaunchAtLogin(enabled)
                    }
                if LaunchAtLogin.needsApproval {
                    Notice(
                        text: String(localized: "macOS needs you to allow CleanBar in Login Items."),
                        buttonTitle: String(localized: "Open Login Items"),
                        action: LaunchAtLogin.openLoginItemsSettings
                    )
                }
                if let launchAtLoginError {
                    Text(launchAtLoginError)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Startup")
            }

            Section {
                Picker("Language", selection: $settings.language) {
                    Text("System Language (\(AppLanguage.name(of: AppLanguage.systemDefault)))")
                        .tag(String?.none)
                    Divider()
                    ForEach(AppLanguage.available, id: \.self) { language in
                        Text(AppLanguage.name(of: language))
                            .tag(String?.some(language))
                    }
                }
                if let languageAfterRestart {
                    // In the language CleanBar switches to, which may be the only one the user reads.
                    Notice(
                        text: AppLanguage.string("CleanBar switches to this language when it restarts.", in: languageAfterRestart),
                        kind: .info,
                        buttonTitle: AppLanguage.string("Restart Now", in: languageAfterRestart),
                        action: AppLanguage.restart
                    )
                }
                Picker("Appearance", selection: $settings.appearance) {
                    Text(AppAppearance.system.title).tag(AppAppearance.system)
                    Divider()
                    ForEach([AppAppearance.light, .dark]) { appearance in
                        Text(appearance.title).tag(appearance)
                    }
                }
            }

            Section("Menu Bar Icon") {
                Picker("Icon", selection: $settings.iconStyle) {
                    ForEach(MenuBarIconStyle.allCases) { style in
                        Image(nsImage: style.image(showingHiddenIcons: false, opensBelow: isFloatingBar))
                            .renderingMode(.template)
                            .accessibilityLabel(style.title)
                            .help(style.title)
                            .tag(style)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(settings.hidesIcon)
                Toggle(isOn: $settings.hidesIcon) {
                    Text("Hide the CleanBar icon")
                    Text("To come back to these settings, open CleanBar again from Spotlight or the Applications folder.")
                }
            }

            Section {
                Picker("Show hidden icons", selection: $settings.hiddenIconsStyle) {
                    ForEach(HiddenIconsStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .pickerStyle(.radioGroup)
                Picker("Show them when you", selection: $settings.showHiddenIconsTrigger) {
                    ForEach(ShowHiddenIconsTrigger.allCases) { trigger in
                        Text(trigger.title)
                            .tag(trigger)
                            // Without the icon in the menu bar, there's nothing to click.
                            .selectionDisabled(trigger == .iconClick && settings.hidesIcon)
                    }
                }
                .pickerStyle(.radioGroup)
                Toggle(isOn: $settings.autoHide) {
                    Text("Hide icons again automatically")
                    Text(isFloatingBar
                        ? "CleanBar waits while the pointer is over the floating bar."
                        : "CleanBar waits while the pointer is in the menu bar or a menu is open.")
                }
                LabeledContent("Hide after") {
                    HStack(spacing: 6) {
                        TextField("Hide after", text: $delayText)
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 40)
                            .focused($isEditingDelay)
                            .onSubmit(saveDelay)
                            .onChange(of: isEditingDelay) { _, editing in
                                if !editing { saveDelay() }
                            }
                        Stepper("Hide after", value: $settings.autoHideDelay, in: AppSettings.autoHideDelays)
                            .labelsHidden()
                        Text(settings.autoHideDelay == 1 ? "second" : "seconds")
                    }
                }
                .help("From 1 to 60 seconds")
                .disabled(!settings.autoHide)
                .onAppear(perform: showDelay)
                .onChange(of: settings.autoHideDelay, showDelay)
            } header: {
                Text("Hidden Icons")
            } footer: {
                Text(hiddenIconsFooter)
            }

            Section {
                LabeledContent("Show or hide hidden icons") {
                    ShortcutRecorder(combo: $settings.hotKey)
                }
            } header: {
                Text("Keyboard Shortcut")
            } footer: {
                // With its icon hidden, CleanBar has no other way to quit.
                HStack {
                    Spacer()
                    Button("Quit CleanBar") { NSApp.terminate(nil) }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(SettingsTab.general.title)
    }

    /// The language CleanBar shows itself in once it restarts, while that's not the one it shows now.
    private var languageAfterRestart: String? {
        let language = settings.language ?? AppLanguage.systemDefault
        return language == AppLanguage.current ? nil : language
    }

    /// How hidden icons show, with what the user chose.
    private var hiddenIconsFooter: String {
        var sentences = [String(localized: "Hidden icons leave the menu bar completely.")]
        switch settings.showHiddenIconsTrigger {
        case .iconClick:
            sentences.append(isFloatingBar
                ? String(localized: "Click the CleanBar icon or press your shortcut to see them in a bar below it.")
                : String(localized: "Click the CleanBar icon or press your shortcut to show them where they were."))
        case .emptySpaceHover:
            sentences.append(isFloatingBar
                ? String(localized: "Rest the pointer on an empty space in the menu bar to see them in a bar below it. The bar closes once the pointer has left it and the menu bar.")
                : String(localized: "Rest the pointer on an empty space in the menu bar to show them where they were. They go again once the pointer has left the menu bar."))
        case .emptySpaceClick:
            sentences.append(isFloatingBar
                ? String(localized: "Click an empty space in the menu bar to see them in a bar below it, and again to close it.")
                : String(localized: "Click an empty space in the menu bar to show them where they were, and again to hide them."))
        }
        if settings.showHiddenIconsTrigger != .iconClick {
            sentences.append(settings.hidesIcon
                ? String(localized: "Your shortcut works too.")
                : String(localized: "The CleanBar icon and your shortcut work too."))
        }
        if isFloatingBar {
            sentences.append(String(localized: "Click an icon in the bar to open its menu: the icon comes back at the left end of the menu bar icons until the menu closes."))
        }
        return sentences.joined(separator: " ")
    }

    private func showDelay() {
        delayText = String(Int(settings.autoHideDelay))
    }

    /// Anything out of range becomes the nearest allowed delay; anything that isn't a number puts the old one back.
    private func saveDelay() {
        if let seconds = Double(delayText.trimmingCharacters(in: .whitespaces)) {
            settings.autoHideDelay = AppSettings.autoHideDelay(seconds)
        }
        showDelay()
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        guard enabled != LaunchAtLogin.isEnabled else { return }
        do {
            try LaunchAtLogin.setEnabled(enabled)
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
            launchAtLogin = LaunchAtLogin.isEnabled
        }
    }
}
