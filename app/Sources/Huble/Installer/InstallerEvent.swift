import Foundation

/// One NDJSON line from the installer's stdout (HUBLE_OUTPUT=json).
/// Field names follow docs/installer-contract.md; unknown events are kept in
/// the log and otherwise ignored so a newer installer does not break the app.
struct InstallerEvent: Decodable {
    let event: String
    var message: String?
    var contract: String?
    var version: String?
    var code: String?
    var url: String?
    var path: String?
    var vault: String?
    var platformUpdated: Bool?
    var reason: String?
}

/// What the app asks the installer to do: only env + flags, never a shell string.
struct InstallerAction {
    var title: String
    var env: [String: String]
    var flags: [String] = []
    /// Set for a remove action so a `reason: unsynced` failure can offer
    /// "Remove anyway" (the same action with HUBLE_FORCE=1).
    var removePath: String?

    /// "Remove from this Mac": Trash + forget in Obsidian. The GitHub repository
    /// is never touched by the installer.
    static func removeVault(path: String, force: Bool = false) -> InstallerAction {
        var env = ["HUBLE_VAULT_MODE": "remove", "HUBLE_VAULT_PATH": path].merging(noPlatformUpdate) { a, _ in a }
        if force { env["HUBLE_FORCE"] = "1" }
        let name = (path as NSString).lastPathComponent
        return InstallerAction(title: "Removing “\(name)” from this Mac", env: env, removePath: path)
    }

    /// Every action except setup / updatePlatform leaves the platform checkout
    /// alone (HUBLE_PLATFORM_UPDATE=0): updating is an explicit button, shown
    /// only when `--check` says an update exists — same rule as the plugin.
    private static let noPlatformUpdate = ["HUBLE_PLATFORM_UPDATE": "0"]

    static func setup() -> InstallerAction {
        InstallerAction(title: "Setting up this Mac", env: ["HUBLE_VAULT_MODE": "skip", "HUBLE_VAULT_REINIT": "no", "HUBLE_NO_OPEN": "1"])
    }

    /// gh missing or signed out: the same full run as setup, named for what it fixes.
    static func signInGitHub() -> InstallerAction {
        InstallerAction(title: "Signing in to GitHub", env: ["HUBLE_VAULT_MODE": "skip", "HUBLE_VAULT_REINIT": "no", "HUBLE_NO_OPEN": "1"])
    }

    static func updatePlatform() -> InstallerAction {
        InstallerAction(title: "Updating the platform", env: ["HUBLE_VAULT_MODE": "skip", "HUBLE_VAULT_REINIT": "no", "HUBLE_NO_OPEN": "1"])
    }

    /// Re-installs the vault's plugin/skills/commands from the platform already
    /// on this Mac (`huble cx init`). Not a sync: no pull, no client data touched.
    static func updateVault(path: String) -> InstallerAction {
        InstallerAction(title: "Updating Atlas in “\((path as NSString).lastPathComponent)”", env: ["HUBLE_VAULT_MODE": "skip", "HUBLE_VAULT_REINIT": path, "HUBLE_NO_OPEN": "1"].merging(noPlatformUpdate) { a, _ in a })
    }

    static func newProject(client: String, role: String, vaultsDir: String) -> InstallerAction {
        // HUBLE_NO_OPEN stays unset: the installer registers and opens the vault in Obsidian.
        InstallerAction(title: "Creating project “\(client)”", env: [
            "HUBLE_VAULT_MODE": "new", "HUBLE_CLIENT_NAME": client, "HUBLE_ROLE": role, "HUBLE_VAULTS_DIR": vaultsDir,
        ].merging(noPlatformUpdate) { a, _ in a })
    }

    /// A vault folder already on this Mac: re-init its plugin/skills for this
    /// machine and open it in Obsidian (HUBLE_NO_OPEN unset). `role` is only
    /// used when the vault never recorded one.
    static func openLocal(path: String, role: String?) -> InstallerAction {
        var env = ["HUBLE_VAULT_MODE": "skip", "HUBLE_VAULT_REINIT": path].merging(noPlatformUpdate) { a, _ in a }
        if let role { env["HUBLE_ROLE"] = role }
        let name = (path as NSString).lastPathComponent
        return InstallerAction(title: "Opening “\(name)”", env: env)
    }

    static func cloneProject(repo: String, role: String, vaultsDir: String) -> InstallerAction {
        InstallerAction(title: "Cloning project \(repo)", env: [
            "HUBLE_VAULT_MODE": "clone", "HUBLE_VAULT_REPO": repo, "HUBLE_ROLE": role, "HUBLE_VAULTS_DIR": vaultsDir,
        ].merging(noPlatformUpdate) { a, _ in a })
    }
}
