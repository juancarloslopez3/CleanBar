import AppKit
import Carbon.HIToolbox
import SwiftUI

struct ShortcutRecorder: View {
    @Binding var combo: HotKeyCombo?
    @State private var recorder = ShortcutRecorderModel()

    var body: some View {
        HStack(spacing: 6) {
            if combo != nil, !recorder.isRecording {
                Button {
                    combo = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Remove shortcut")
            }
            // While recording, the button stands out in the accent color, like a field waiting for input.
            if recorder.isRecording {
                Button(action: recorder.stop) {
                    Text("Type a shortcut…")
                        .frame(minWidth: 110)
                }
                .buttonStyle(.borderedProminent)
                .help("Press the keys of your shortcut, or Escape to cancel")
            } else {
                Button {
                    recorder.onRecord = { combo = $0 }
                    recorder.start()
                } label: {
                    Text(combo?.displayString ?? String(localized: "Record Shortcut"))
                        .frame(minWidth: 110)
                }
                .help("Click, then press the keys of your shortcut")
            }
        }
        .onDisappear { recorder.stop() }
    }
}

@Observable
final class ShortcutRecorderModel {
    private(set) var isRecording = false
    @ObservationIgnored var onRecord: ((HotKeyCombo) -> Void)?
    @ObservationIgnored private var monitor: Any?

    func start() {
        guard !isRecording else { return }
        isRecording = true
        HotKeyCenter.shared.isPaused = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                self?.handle(keyCode: event.keyCode, modifiers: event.modifierFlags, characters: event.charactersIgnoringModifiers) ?? false
            }
            return handled ? nil : event
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        isRecording = false
        HotKeyCenter.shared.isPaused = false
    }

    private func handle(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, characters: String?) -> Bool {
        if Int(keyCode) == kVK_Escape {
            stop()
            return true
        }
        let flags = modifiers.intersection(.shortcutKeys)
        // A shortcut needs ⌘, ⌥ or ⌃, or it would swallow normal typing.
        guard !flags.isDisjoint(with: [.command, .option, .control]) else {
            NSSound.beep()
            return true
        }
        let label = HotKeyCombo.label(forKeyCode: keyCode, characters: characters)
        onRecord?(HotKeyCombo(keyCode: UInt32(keyCode), modifiers: flags.rawValue, keyLabel: label))
        stop()
        return true
    }
}
