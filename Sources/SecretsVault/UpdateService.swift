import Foundation
import AppKit
import CryptoKit
import SecretsVaultCore

/// In-app updater backed by GitHub Releases.
///
/// Releases are published by the pre-push git hook (`scripts/git-hooks/pre-push`),
/// which attaches a zipped `.app` and its SHA-256 to a `v<version>` tag for every
/// push to main. This service asks the GitHub API for the latest release, compares
/// it with the running build, and — on the user's click — downloads the zip,
/// verifies it, swaps the app bundle on disk and relaunches.
///
/// Nothing is installed unless (see `CodeSignature`):
/// - the zip matches the `.sha256` published with the release, when there is one;
/// - the extracted bundle has an intact code signature and our bundle identifier;
/// - when the running app is signed with an Apple-issued certificate, the new
///   bundle is signed by the same Team ID under the Apple anchor;
/// - for an ad-hoc-signed build, which has no identity to pin to, the published
///   checksum is required rather than optional.
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
        /// The "<asset>.sha256" attachment, when the release has one.
        let checksumURL: URL?
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
                   !AppVersion.isNewer(release.version, than: current) {
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
        let checksum = api.assets.first { $0.name == asset.name + ".sha256" }
        let version = api.tagName.hasPrefix("v") ? String(api.tagName.dropFirst()) : api.tagName
        return Release(version: version,
                       tag: api.tagName,
                       notes: api.body ?? "",
                       pageURL: api.htmlURL,
                       assetURL: asset.browserDownloadURL,
                       checksumURL: checksum?.browserDownloadURL)
    }

    // MARK: - Download, verify, bundle swap

    nonisolated private static func install(_ release: Release) async throws {
        let fm = FileManager.default
        let destination = Bundle.main.bundleURL
        let parent = destination.deletingLastPathComponent()
        guard destination.pathExtension == "app" else { throw err("Not running from an .app bundle.") }
        guard fm.isWritableFile(atPath: parent.path) else {
            throw err("Cannot write to \(parent.path) — move the app to a folder you own and try again.")
        }
        let running = try CodeSignature.runningApp()

        let work = fm.temporaryDirectory
            .appendingPathComponent("SecretsVault-update-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        do {
            try await stage(release, in: work, running: running, destination: destination)
        } catch {
            try? fm.removeItem(at: work)
            throw error
        }
    }

    /// Downloads into `work`, verifies, and hands off to the swap helper.
    /// Only returns by throwing: on success the app terminates.
    nonisolated private static func stage(_ release: Release, in work: URL,
                                          running: CodeSignature.RunningApp,
                                          destination: URL) async throws {
        let fm = FileManager.default

        // 1. Download the zip attached to the release.
        let (downloaded, response) = try await URLSession.shared.download(from: release.assetURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw err("Download failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)).")
        }
        let zip = work.appendingPathComponent("update.zip")
        try fm.moveItem(at: downloaded, to: zip)

        // 2. Integrity: the zip must match the checksum published with the
        //    release. Signed builds are also authenticated by their code
        //    signature in step 4; an ad-hoc build has nothing to pin to, so
        //    for it the checksum is the only check and therefore required.
        if let checksumURL = release.checksumURL {
            try await verifyChecksum(of: zip, against: checksumURL)
        } else if running.identity == .adhoc {
            throw err("Release \(release.tag) publishes no checksum and this build is ad-hoc signed, so the download cannot be verified. Nothing was installed.")
        }

        // 3. Extract and sanity-check the new bundle.
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

        // 4. Authenticity: intact signature, same bundle ID, same team.
        try CodeSignature.verify(bundle: newApp, replaces: running)

        // 5. Hand off to a helper that waits for this process to exit, swaps
        //    the bundle and relaunches — then quit.
        let script = work.appendingPathComponent("install.sh")
        try installScript.write(to: script, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/bash")
        helper.arguments = [script.path,
                            String(ProcessInfo.processInfo.processIdentifier),
                            newApp.path,
                            destination.path,
                            work.path]
        try helper.run()

        // The vault is saved by AppDelegate.applicationShouldTerminate. This
        // only returns when that save failed and the quit was vetoed.
        await MainActor.run { NSApp.terminate(nil) }
        helper.terminate()
        throw err("The update was not installed because the vault could not be saved. Fix the save error and try again.")
    }

    nonisolated private static func verifyChecksum(of file: URL, against checksumURL: URL) async throws {
        let (data, response) = try await URLSession.shared.data(from: checksumURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let text = String(data: data, encoding: .utf8),
              let expected = text.split(whereSeparator: \.isWhitespace).first.map({ $0.lowercased() }),
              expected.count == 64, expected.allSatisfy(\.isHexDigit) else {
            throw err("Could not read the checksum published with the release.")
        }
        let digest = SHA256.hash(data: try Data(contentsOf: file))
        let actual = digest.map { String(format: "%02x", $0) }.joined()
        guard actual == expected else {
            throw err("The downloaded update does not match the checksum published with the release — it may be corrupted or tampered with. Nothing was installed.")
        }
    }

    /// Waits for the old process to exit, stages the verified bundle next to
    /// the destination, swaps it in with two renames (so a failed copy never
    /// leaves the user without an app), and relaunches.
    nonisolated private static let installScript = """
    #!/bin/bash
    # Secrets Vault update helper (auto-generated, runs from a temp dir).
    PID="$1"; NEW="$2"; DEST="$3"; WORK="$4"
    case "$DEST" in *.app) ;; *) exit 1 ;; esac
    for _ in $(seq 1 600); do
      kill -0 "$PID" 2>/dev/null || break
      sleep 0.1
    done
    if kill -0 "$PID" 2>/dev/null; then
      echo "Secrets Vault is still running; update aborted." >&2
      exit 1
    fi
    PARENT="$(dirname "$DEST")"
    STAGED="$PARENT/.SecretsVault-update-$$.app"
    OLD="$PARENT/.SecretsVault-old-$$.app"
    rm -rf "$STAGED"
    if ! /usr/bin/ditto "$NEW" "$STAGED"; then rm -rf "$STAGED"; exit 1; fi
    /usr/bin/xattr -dr com.apple.quarantine "$STAGED" 2>/dev/null
    if ! mv "$DEST" "$OLD"; then rm -rf "$STAGED"; exit 1; fi
    if ! mv "$STAGED" "$DEST"; then mv "$OLD" "$DEST"; exit 1; fi
    rm -rf "$OLD"
    case "$WORK" in */SecretsVault-update-*) rm -rf "$WORK" ;; esac
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
