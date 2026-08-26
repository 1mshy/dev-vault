import Foundation
import AppKit

/// In-app updater backed by GitHub Releases.
///
/// Releases are published by the pre-push git hook (`scripts/git-hooks/pre-push`),
/// which attaches a zipped `.app` to a `v<version>` tag for every push to main.
/// This service asks the GitHub API for the latest release, compares it with the
/// running build, and — on the user's click — downloads the zip, swaps the app
/// bundle on disk and relaunches.
@MainActor
final class UpdateService: ObservableObject {

    nonisolated static let owner = "1mshy"
    nonisolated static let repo = "dev-vault"

    struct Release: Equatable {
        let version: String   // "1.0.42"
        let tag: String       // "v1.0.42"
        let notes: String
        let pageURL: URL?
        let assetURL: URL
    }

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate(latest: String)
        case available(Release)
        case downloading
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle

    /// Version of the running build; nil for a bare debug binary (`swift run`),
    /// which has no bundle that could be replaced.
    static var currentVersion: String? {
        guard Bundle.main.bundlePath.hasSuffix(".app") else { return nil }
        return Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    /// Whether the running instance can be updated in place.
    var canUpdate: Bool { Self.currentVersion != nil }

    // MARK: - Checking

    func check() {
        if phase == .checking || phase == .downloading { return }
        phase = .checking
        Task {
            do {
                guard let release = try await Self.fetchLatestRelease() else {
                    phase = .failed("No releases have been published yet.")
                    return
                }
                if let current = Self.currentVersion,
                   !Self.isNewer(release.version, than: current) {
                    phase = .upToDate(latest: release.version)
                } else {
                    phase = .available(release)
                }
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - Installing

    func downloadAndInstall(_ release: Release) {
        guard canUpdate else {
            phase = .failed("Not running from an .app bundle — build with ./build.sh first.")
            return
        }
        if phase == .downloading { return }
        phase = .downloading
        Task {
            do {
                try await Self.install(release)   // terminates the app on success
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - GitHub API

    private struct APIRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: URL
            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }
        let tagName: String
        let body: String?
        let htmlURL: URL?
        let assets: [Asset]
        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case body
            case htmlURL = "html_url"
            case assets
        }
    }

    nonisolated private static func fetchLatestRelease() async throws -> Release? {
        let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw err("Unexpected response from GitHub.") }
        if http.statusCode == 404 { return nil }   // no releases yet
        guard http.statusCode == 200 else { throw err("GitHub API returned HTTP \(http.statusCode).") }
        let api = try JSONDecoder().decode(APIRelease.self, from: data)
        guard let asset = api.assets.first(where: { $0.name.hasSuffix(".zip") }) else {
            throw err("Release \(api.tagName) has no .zip attachment.")
        }
        let version = api.tagName.hasPrefix("v") ? String(api.tagName.dropFirst()) : api.tagName
        return Release(version: version,
                       tag: api.tagName,
                       notes: api.body ?? "",
                       pageURL: api.htmlURL,
                       assetURL: asset.browserDownloadURL)
    }

    /// True when version `a` is strictly newer than `b` ("1.0.10" beats "1.0.9").
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            var s = s
            if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
            if let dash = s.firstIndex(of: "-") { s = String(s[..<dash]) }   // "1.0.5-dev"
            return s.split(separator: ".").map { Int($0) ?? 0 }
        }
        var x = parts(a), y = parts(b)
        while x.count < y.count { x.append(0) }
        while y.count < x.count { y.append(0) }
        for (p, q) in zip(x, y) where p != q { return p > q }
        return false
    }

    // MARK: - Bundle swap

    nonisolated private static func install(_ release: Release) async throws {
        let fm = FileManager.default
        let destination = Bundle.main.bundleURL
        let parent = destination.deletingLastPathComponent()
        guard destination.pathExtension == "app" else { throw err("Not running from an .app bundle.") }
        guard fm.isWritableFile(atPath: parent.path) else {
            throw err("Cannot write to \(parent.path) — move the app to a folder you own and try again.")
        }

        let work = fm.temporaryDirectory
            .appendingPathComponent("SecretsVault-update-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)

        // 1. Download the zip attached to the release.
        let (downloaded, response) = try await URLSession.shared.download(from: release.assetURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw err("Download failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)).")
        }
        let zip = work.appendingPathComponent("update.zip")
        try fm.moveItem(at: downloaded, to: zip)

        // 2. Extract and sanity-check the new bundle.
        let extracted = work.appendingPathComponent("extracted", isDirectory: true)
        try run("/usr/bin/ditto", "-xk", zip.path, extracted.path)
        guard let newApp = try fm.contentsOfDirectory(at: extracted, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }) else {
            throw err("The downloaded update contains no .app bundle.")
        }
        let newExecutable = newApp.appendingPathComponent("Contents/MacOS/SecretsVault")
        guard fm.isExecutableFile(atPath: newExecutable.path) else {
            throw err("The downloaded update looks damaged (missing executable).")
        }

        // 3. Hand off to a helper that waits for this process to exit, swaps
        //    the bundle and relaunches — then quit.
        let script = work.appendingPathComponent("install.sh")
        try installScript.write(to: script, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/bash")
        helper.arguments = [script.path,
                            String(ProcessInfo.processInfo.processIdentifier),
                            newApp.path,
                            destination.path]
        try helper.run()

        await MainActor.run { NSApp.terminate(nil) }   // saves + locks via willTerminate
    }

    /// Waits for the old process to exit, replaces the bundle, relaunches.
    nonisolated private static let installScript = """
    #!/bin/bash
    # Secrets Vault update helper (auto-generated, runs from a temp dir).
    PID="$1"; NEW="$2"; DEST="$3"
    case "$DEST" in *.app) ;; *) exit 1 ;; esac
    for _ in $(seq 1 600); do
      kill -0 "$PID" 2>/dev/null || break
      sleep 0.1
    done
    rm -rf "$DEST"
    /usr/bin/ditto "$NEW" "$DEST"
    /usr/bin/xattr -dr com.apple.quarantine "$DEST" 2>/dev/null
    /usr/bin/open "$DEST"
    """

    @discardableResult
    nonisolated private static func run(_ tool: String, _ args: String...) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw err("\(URL(fileURLWithPath: tool).lastPathComponent) failed with status \(p.terminationStatus).")
        }
        return p.terminationStatus
    }

    nonisolated private static func err(_ message: String) -> NSError {
        NSError(domain: "SecretsVault.UpdateService", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
