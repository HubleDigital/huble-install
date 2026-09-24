import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    /// Whether the platform is on this Mac decides fresh-Mac vs main window.
    /// `~/.huble/install.sh` is NOT the signal: Macs set up before contract v1
    /// have the platform but no saved installer, and must not look fresh.
    var platformPresent = Bootstrap.platformExists
    var installerPresent = Bootstrap.installerExists
    /// Set while the saved installer is missing on a set-up Mac and the
    /// background download has not succeeded yet (nil = not attempted / ok).
    var installerFetchError: String?
    var fetchingInstaller = false
    var state = InstallerState.load()
    var vaults: [LocalVault] = []
    var platformVersion: String?
    /// Version of the Atlas plugin the platform ships (what `cx init` installs).
    var platformPluginVersion: String?
    var githubLogin: String?
    var ghInstalled = false
    var updateCheck: UpdateCheck?
    var checkingUpdates = false
    private var lastCheckAt: Date?
    var activeRun: InstallerRun?
    var showNewProject = false
    var showCloneProject = false
    var showOpenProject = false
    var bootstrapError: String?
    var bootstrapping = false

    /// Re-read local state. The update check hits the network, so it only
    /// repeats after `checkInterval` unless `forceCheck` (after an installer run).
    func refresh(forceCheck: Bool = false) {
        platformPresent = Bootstrap.platformExists
        installerPresent = Bootstrap.installerExists
        if platformPresent && !installerPresent { Task { await ensureInstaller() } }
        state = InstallerState.load()
        vaults = VaultScanner.scan(state)
        platformPluginVersion = VaultScanner.manifestVersion(at: Shell.hubleHome + "/platform/huble-pipeline/dist/atlas-cx/manifest.json")
        Task { await loadFooter() }
        let stale = lastCheckAt.map { Date().timeIntervalSince($0) > Self.checkInterval } ?? true
        if forceCheck || stale { Task { await checkForUpdates() } }
    }

    static let checkInterval: TimeInterval = 30 * 60

    /// Platform present, saved installer missing (pre-v1 install): fetch the
    /// installer silently. Download only — nothing runs. On failure the main
    /// window shows a banner with Retry and the installer-driven actions stay
    /// disabled; the Mac is never shown as fresh.
    func ensureInstaller() async {
        guard platformPresent, !installerPresent, !fetchingInstaller else { return }
        fetchingInstaller = true
        defer { fetchingInstaller = false }
        do {
            try await Bootstrap.downloadInstaller()
            installerPresent = Bootstrap.installerExists
            installerFetchError = installerPresent ? nil : "Downloaded, but ~/.huble/install.sh is still not readable."
            if installerPresent { await checkForUpdates() }
        } catch {
            installerFetchError = error.localizedDescription
        }
    }

    func checkForUpdates() async {
        guard !checkingUpdates else { return }
        checkingUpdates = true
        defer { checkingUpdates = false }
        updateCheck = await UpdateCheck.run()
        lastCheckAt = Date()
    }

    /// "Update Atlas" only when the installed plugin is OLDER than the one the
    /// platform ships — never a downgrade (a newer test build stays). Missing
    /// manifest → update. Same rule as the plugin's Get Started
    /// (huble-pipeline/scripts/atlas-version.mjs).
    func vaultNeedsUpdate(_ vault: LocalVault) -> Bool {
        guard let shipped = platformPluginVersion else { return false }
        guard let installed = vault.pluginVersion else { return true }
        guard let cmp = AtlasVersion.compare(installed, shipped) else { return false }
        return cmp == .orderedAscending
    }

    func run(_ action: InstallerAction) {
        let run = InstallerRun(action: action)
        activeRun = run
        run.start()
    }

    func setUpThisMac() async {
        bootstrapping = true
        bootstrapError = nil
        defer { bootstrapping = false }
        do {
            if !Bootstrap.installerExists { try await Bootstrap.downloadInstaller() }
            installerPresent = Bootstrap.installerExists
            run(.setup())
        } catch {
            bootstrapError = error.localizedDescription
        }
    }

    private func loadFooter() async {
        let platform = Shell.hubleHome + "/platform"
        if let r = try? await Shell.run("/usr/bin/git", ["-C", platform, "log", "-1", "--format=%h %cs"]), r.status == 0 {
            platformVersion = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            platformVersion = nil
        }
        if let gh = Shell.gh() {
            ghInstalled = true
            if let r = try? await Shell.run(gh, ["api", "user", "--jq", ".login"]), r.status == 0 {
                githubLogin = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                githubLogin = nil
            }
        } else {
            ghInstalled = false
            githubLogin = nil
        }
    }
}
