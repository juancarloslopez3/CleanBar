import AppKit
import SwiftUI

/// Looks for a newer CleanBar on GitHub Releases every 30 days. When there is one it asks whether to install it; when
/// there isn't, it shows nothing. Installing downloads the release's .dmg, copies the app out of it, and replaces this
/// copy once CleanBar has quit, then opens the new one.
@MainActor
final class UpdateChecker {
    static let shared = UpdateChecker()

    /// What a check found, for the About pane's own Check for Updates button.
    enum Outcome: Equatable {
        case upToDate
        case updateAvailable
        case failed
    }

    private static let latestReleaseURL = URL(string: "https://api.github.com/repos/juancarloslopez3/cleanbar/releases/latest")!
    private static let lastCheckKey = "lastUpdateCheck"
    private static let checkInterval: TimeInterval = 30 * 24 * 60 * 60

    private var timer: Timer?
    private var isChecking = false
    private var isInstalling = false
    private var progressPanel: NSPanel?

    private init() {}

    /// Checks now if the last check was 30 days ago or more (or never), and looks again every few hours whether it's
    /// due, for a Mac that stays on for weeks.
    func start() {
        checkIfDue()
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { _ in
            Task { @MainActor in UpdateChecker.shared.checkIfDue() }
        }
    }

    private func checkIfDue() {
        if let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date,
           Date().timeIntervalSince(last) < Self.checkInterval {
            return
        }
        Task { await check() }
    }

    /// Fetches the latest release and shows the update popup if it's newer than this version.
    @discardableResult
    func check() async -> Outcome {
        guard !isChecking, !isInstalling else { return .upToDate }
        isChecking = true
        defer { isChecking = false }

        let release: Release
        do {
            var request = URLRequest(url: Self.latestReleaseURL)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("CleanBar/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 30
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return .failed }
            release = try JSONDecoder().decode(Release.self, from: data)
        } catch {
            // Offline, say: the next timer tick tries again, since the date isn't saved.
            return .failed
        }
        UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)

        guard Self.isVersion(release.version, newerThan: Self.currentVersion) else { return .upToDate }
        showUpdateAlert(for: release)
        return .updateAvailable
    }

    // MARK: Popup

    private func showUpdateAlert(for release: Release) {
        let alert = NSAlert()
        alert.messageText = String(localized: "CleanBar \(release.version) is available")
        var info = String(localized: "You have version \(Self.currentVersion). CleanBar will download the new version and restart to install it.")
        if let notes = release.notes {
            info += "\n\n" + notes
        }
        alert.informativeText = info
        alert.addButton(withTitle: String(localized: "Download and Restart"))
        alert.addButton(withTitle: String(localized: "Later"))
        NSApp.activate()
        alert.window.level = .floating
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await install(release) }
    }

    private func showFailure(_ message: String, release: Release) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "CleanBar couldn't install the update")
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "Open Download Page"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        NSApp.activate()
        alert.window.level = .floating
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(release.pageURL)
        }
    }

    // MARK: Installing

    private func install(_ release: Release) async {
        guard !isInstalling else { return }
        let appURL = Bundle.main.bundleURL
        let parent = appURL.deletingLastPathComponent()
        guard let dmgURL = release.dmgURL else {
            showFailure(String(localized: "The release has no disk image to download."), release: release)
            return
        }
        // A translocated copy (opened straight from Downloads or the disk image) or one in a folder CleanBar can't
        // write to can't be replaced.
        guard !appURL.path.contains("/AppTranslocation/"), FileManager.default.isWritableFile(atPath: parent.path) else {
            showFailure(String(localized: "Move CleanBar to the Applications folder, or download the update yourself."), release: release)
            return
        }

        isInstalling = true
        defer { isInstalling = false }
        let progress = DownloadProgress(version: release.version)
        showProgressPanel(progress)
        defer { closeProgressPanel() }

        do {
            // On the app's own volume, so the final swap is a rename.
            let work = try FileManager.default.url(
                for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: appURL, create: true)
            let dmg = try await download(dmgURL, to: work.appending(path: "CleanBar.dmg"), progress: progress)
            guard !progress.isCancelled else { return }
            progress.phase = .installing
            let staged = work.appending(path: appURL.lastPathComponent)
            try await Self.extractApp(from: dmg, to: staged, work: work)
            try Self.verify(staged, expectedVersion: release.version)
            guard !progress.isCancelled else { return }
            Self.replaceAndRelaunch(appURL, with: staged, work: work)
        } catch is CancellationError {
            return
        } catch {
            closeProgressPanel()
            showFailure((error as? UpdateError)?.message ?? error.localizedDescription, release: release)
        }
    }

    private func download(_ url: URL, to destination: URL, progress: DownloadProgress) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let task = URLSession.shared.downloadTask(with: url) { location, response, error in
                if let error {
                    continuation.resume(throwing: (error as? URLError)?.code == .cancelled ? CancellationError() : error)
                    return
                }
                guard let location, (response as? HTTPURLResponse)?.statusCode == 200 else {
                    continuation.resume(throwing: UpdateError(message: String(localized: "The download failed.")))
                    return
                }
                do {
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.moveItem(at: location, to: destination)
                    continuation.resume(returning: destination)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            progress.observe(task)
            task.resume()
        }
    }

    /// Mounts the disk image privately, copies the CleanBar inside it out, and unmounts it.
    private nonisolated static func extractApp(from dmg: URL, to staged: URL, work: URL) async throws {
        let mount = work.appending(path: "mount")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        try await run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-noverify",
                                           "-mountpoint", mount.path])
        defer { _ = try? runSync("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }

        let bundleID = Bundle.main.bundleIdentifier
        let apps = (try? FileManager.default.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil)) ?? []
        guard let app = apps.first(where: {
            $0.pathExtension == "app" && Bundle(url: $0)?.bundleIdentifier == bundleID
        }) else {
            throw UpdateError(message: String(localized: "The disk image doesn't contain CleanBar."))
        }
        try await run("/usr/bin/ditto", [app.path, staged.path])
    }

    /// The copy must be a whole, validly signed CleanBar of the version the release says.
    private static func verify(_ staged: URL, expectedVersion: String) throws {
        let bundle = Bundle(url: staged)
        let version = bundle?.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        guard bundle?.bundleIdentifier == Bundle.main.bundleIdentifier,
              isVersion(version, newerThan: currentVersion) || version == expectedVersion else {
            throw UpdateError(message: String(localized: "The downloaded app isn't a newer CleanBar."))
        }
        guard (try? runSync("/usr/bin/codesign", ["--verify", "--deep", "--strict", staged.path])) == 0 else {
            throw UpdateError(message: String(localized: "The downloaded app's signature isn't valid."))
        }
    }

    /// Quits, then a shell swaps the new app in (putting the old one back if that fails) and opens it.
    private static func replaceAndRelaunch(_ appURL: URL, with staged: URL, work: URL) {
        let old = work.appending(path: "Old.app")
        let script = """
            while /bin/kill -0 "$1" 2>/dev/null; do /bin/sleep 0.1; done
            if /bin/mv "$2" "$4"; then
                if /bin/mv "$3" "$2"; then /bin/rm -rf "$5"; else /bin/mv "$4" "$2"; fi
            fi
            /usr/bin/open "$2"
            """
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", script, "sh", String(ProcessInfo.processInfo.processIdentifier),
                          appURL.path, staged.path, old.path, work.path]
        do {
            try task.run()
        } catch {
            return
        }
        NSApp.terminate(nil)
    }

    // MARK: Progress panel

    private func showProgressPanel(_ progress: DownloadProgress) {
        let panel = NSPanel(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = String(localized: "Updating CleanBar")
        panel.contentView = NSHostingView(rootView: DownloadProgressView(progress: progress))
        panel.setContentSize(panel.contentView?.fittingSize ?? NSSize(width: 360, height: 110))
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.center()
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        progressPanel = panel
    }

    private func closeProgressPanel() {
        progressPanel?.close()
        progressPanel = nil
    }

    // MARK: Versions

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Compares dotted versions number by number, so 1.10 is newer than 1.9 and 1.1 equals 1.1.0. A leading "v" is
    /// ignored.
    nonisolated static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        func parts(_ version: String) -> [Int] {
            let trimmed = version.hasPrefix("v") || version.hasPrefix("V") ? String(version.dropFirst()) : version
            return trimmed.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: Processes

    private nonisolated static func run(_ path: String, _ arguments: [String]) async throws {
        let status = try await Task.detached { try runSync(path, arguments) }.value
        guard status == 0 else {
            throw UpdateError(message: String(localized: "The update couldn't be unpacked."))
        }
    }

    @discardableResult
    private nonisolated static func runSync(_ path: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}

private struct UpdateError: Error {
    let message: String
}

/// The part of GitHub's release JSON CleanBar reads.
private struct Release: Decodable {
    let tagName: String
    let htmlURL: URL
    let body: String?
    let assets: [Asset]

    struct Asset: Decodable {
        let name: String
        let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case body, assets
    }

    var version: String {
        tagName.hasPrefix("v") || tagName.hasPrefix("V") ? String(tagName.dropFirst()) : tagName
    }

    var pageURL: URL { htmlURL }

    /// Only GitHub's own download links.
    var dmgURL: URL? {
        assets.first {
            $0.name.lowercased().hasSuffix(".dmg") && $0.browserDownloadURL.scheme == "https"
                && $0.browserDownloadURL.host()?.hasSuffix("github.com") == true
        }?.browserDownloadURL
    }

    /// The release notes, short enough for a popup.
    var notes: String? {
        guard let body = body?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty else { return nil }
        return body.count > 600 ? String(body.prefix(600)) + "…" : body
    }
}

// MARK: Progress UI

@MainActor
@Observable
private final class DownloadProgress {
    enum Phase { case downloading, installing }

    let version: String
    var fraction: Double = 0
    var phase: Phase = .downloading
    private(set) var isCancelled = false
    @ObservationIgnored private var task: URLSessionTask?
    @ObservationIgnored private var observation: NSKeyValueObservation?

    init(version: String) {
        self.version = version
    }

    func observe(_ task: URLSessionTask) {
        self.task = task
        observation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            let fraction = progress.fractionCompleted
            Task { @MainActor in self?.fraction = fraction }
        }
    }

    func cancel() {
        isCancelled = true
        task?.cancel()
    }
}

private struct DownloadProgressView: View {
    let progress: DownloadProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(progress.phase == .downloading
                 ? "Downloading CleanBar \(progress.version)…"
                 : "Installing CleanBar \(progress.version)…")
                .font(.headline)
            if progress.phase == .downloading {
                ProgressView(value: progress.fraction)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            HStack {
                Spacer()
                Button("Cancel") { progress.cancel() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(progress.phase == .installing)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}
