import SwiftUI

/// CleanBar's icon, name and version, with links to its GitHub page, like the About panes of other Mac apps.
struct AboutView: View {
    /// CleanBar's page on GitHub.
    static let repositoryURL = URL(string: "https://github.com/juancarloslopez3/cleanbar")!
    /// Where new versions come out.
    static let releasesURL = repositoryURL.appending(path: "releases")

    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 112, height: 112)
                .accessibilityHidden(true)
                .padding(.bottom, 14)
            Text(Self.name)
                .font(.title.bold())
            Text("Version \(Self.version)")
                .font(.title3)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.top, 2)
            HStack(spacing: 12) {
                Button("Check for Updates…") { openURL(Self.releasesURL) }
                    .help("Open CleanBar's releases on GitHub")
                Button("Star on GitHub") { openURL(Self.repositoryURL) }
                    .help("Open CleanBar's page on GitHub")
            }
            .controlSize(.large)
            .padding(.top, 20)
            Divider()
                .frame(maxWidth: 380)
                .padding(.vertical, 20)
            Text("A simple menu bar organizer.")
                .font(.title3)
            Text("Developed by Juan Carlos López.")
                .foregroundStyle(.secondary)
                .padding(.top, 8)
            if let copyright = Self.copyright {
                Text(copyright)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
            }
        }
        .multilineTextAlignment(.center)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(SettingsTab.about.title)
    }

    private static let info = Bundle.main.infoDictionary ?? [:]

    private static var name: String {
        info["CFBundleDisplayName"] as? String ?? "CleanBar"
    }

    private static var version: String {
        info["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private static var copyright: String? {
        guard let copyright = info["NSHumanReadableCopyright"] as? String, !copyright.isEmpty else { return nil }
        return copyright
    }
}
