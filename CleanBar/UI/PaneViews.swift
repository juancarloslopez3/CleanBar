import SwiftUI

/// A white symbol on a colored rounded square, like the icons of System Settings.
struct SymbolBadge: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 20

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(tint.gradient)
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
            }
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.52, weight: .medium))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// The top of a pane: its icon, its name and what it's for, the way System Settings starts its panes.
struct PaneHeader: View {
    let tab: SettingsTab
    let description: LocalizedStringKey

    var body: some View {
        VStack(spacing: 6) {
            SymbolBadge(symbol: tab.symbol, tint: tab.tint, size: 52)
                .padding(.bottom, 4)
            Text(tab.title)
                .font(.title2.weight(.semibold))
            Text(description)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 460)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}

/// A warning or a note in a pane, with a button when there's something to do about it.
struct Notice: View {
    enum Kind {
        case warning
        case info
    }

    let text: String
    var kind = Kind.warning
    var buttonTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: kind == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .symbolRenderingMode(kind == .warning ? .multicolor : .monochrome)
                .foregroundStyle(Color.accentColor)
                .font(.title3)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let buttonTitle, let action {
                Button(buttonTitle, action: action)
            }
        }
    }
}
