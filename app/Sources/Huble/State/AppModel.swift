import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    var installerPresent = Bootstrap.installerExists
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
        installerPresent = Bootstrap.installerExists
        state = InstallerState.load()
        vaults = VaultScanner.scan(state)
        platformPluginVersion = VaultScanner.manifestVersion(at: Shell.hubleHome + "/platform/huble-pipeline/dist/atlas-cx/manifest.json")
        Task { await loadFooter() }
        let stale = lastCheckAt.map { Date().timeIntervalSince($0) > Self.checkInterval } ?? true
        if forceCheck || stale { Task { await checkForUpdates() } }
    }

    static let checkInterval: TimeInterval = 30 * 60

    func checkForUpdates() async {
        guard !checkingUpdates else { return }
        checkingUpdates = true
        defer { checkingUpdates = false }
        updateCheck = await UpdateCheck.run()
        lastCheckAt = Date()
    }

    func vaultNeedsUpdate(_ vault: LocalVault) -> Bool {
        guard let shipped = platformPluginVersion else { return false }
        return vault.pluginVersion != shipped
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
            installerPresent = true
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
