import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    var installerPresent = Bootstrap.installerExists
    var state = InstallerState.load()
    var vaults: [LocalVault] = []
    var platformVersion: String?
    var githubLogin: String?
    var activeRun: InstallerRun?
    var showNewProject = false
    var showOpenExisting = false
    var bootstrapError: String?
    var bootstrapping = false

    func refresh() {
        installerPresent = Bootstrap.installerExists
        state = InstallerState.load()
        vaults = VaultScanner.scan(state)
        Task { await loadFooter() }
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
        if let gh = Shell.gh(),
           let r = try? await Shell.run(gh, ["api", "user", "--jq", ".login"]), r.status == 0 {
            githubLogin = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            githubLogin = nil
        }
    }
}
